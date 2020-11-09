{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Text.Regex.Pcre2.Internal where

import           Control.Applicative        (Alternative(..))
import           Control.Exception          hiding (TypeError)
import           Control.Monad.State.Strict
import           Data.Either                (partitionEithers)
import           Data.Function              ((&))
import           Data.Functor               ((<&>))
import           Data.Functor.Const         (Const(..))
import           Data.Functor.Identity      (Identity(..))
import           Data.IORef
import           Data.IntMap.Strict         (IntMap)
import qualified Data.IntMap.Strict         as IM
import           Data.List                  (foldl', intercalate)
import           Data.List.NonEmpty         (NonEmpty(..))
import qualified Data.List.NonEmpty         as NE
import           Data.Maybe                 (fromJust, fromMaybe)
import           Data.Monoid                (Any(..), First(..))
import           Data.Proxy                 (Proxy(..))
import           Data.Text                  (Text)
import qualified Data.Text                  as Text
import qualified Data.Text.Foreign          as Text
import           Data.Type.Bool             (type (||), If)
import           Data.Type.Equality         (type (==))
import           Data.Typeable              (cast)
import           Foreign
import           Foreign.C.Types
import qualified Foreign.Concurrent         as Conc
import           GHC.TypeLits               hiding (Text)
import qualified GHC.TypeLits               as TypeLits
import           System.IO.Unsafe           (unsafePerformIO)
import           Text.Regex.Pcre2.Foreign

-- | A register that stores data computed during callouts, such as exceptions
-- thrown, that will be inspected after @pcre2_match@ or similar completes.
data CalloutState = CalloutState {
    calloutStateException :: Maybe SomeException,
    calloutStateSubsLog   :: IntMap SubCalloutResult}

data CompileEnv = CompileEnv {
    compileEnvForeignPtr :: Maybe CompileContext,
    compileEnvERef       :: Maybe (IORef (Maybe SomeException))}

data MatchEnv = MatchEnv {
    matchEnvForeignPtr :: Maybe MatchContext,
    matchEnvCallout    :: Maybe (CalloutInfo -> IO CalloutResult),
    matchEnvSubCallout :: Maybe (SubCalloutInfo -> IO SubCalloutResult)}

-- | There is no @nullForeignPtr@ to pass to `withForeignPtr`, so we have to
-- fake it with a `Maybe`.
withForeignOrNullPtr :: Maybe (ForeignPtr a) -> (Ptr a -> IO b) -> IO b
withForeignOrNullPtr Nothing   = \action -> action nullPtr
withForeignOrNullPtr (Just fp) = withForeignPtr fp

-- | Helper so we never leak untracked 'Ptr's.
mkForeignPtr :: (Ptr a -> IO ()) -> IO (Ptr a) -> IO (ForeignPtr a)
mkForeignPtr finalize create = create >>= Conc.newForeignPtr <*> finalize

-- | Helper so we never leak untracked 'FunPtr's.
mkFunPtr :: ForeignPtr b -> IO (FunPtr a) -> IO (FunPtr a)
mkFunPtr anchor create = do
    fPtr <- create
    Conc.addForeignPtrFinalizer anchor $ freeHaskellFunPtr fPtr
    return fPtr

safeLast :: [a] -> Maybe a
safeLast [] = Nothing
safeLast xs = Just $ last xs

type ExtractOpts a = StateT [AppliedOption] IO a

extractCompileEnv :: ExtractOpts CompileEnv
extractCompileEnv = do
    ctxUpds <- extractCompileContextUpdates
    xtraOpts <- extractCompileExtraOptions
    recGuard <- extractRecursionGuard

    compileEnvForeignPtr <- sequence $ do
        guard $ not $ null ctxUpds && xtraOpts == 0 && null recGuard
        Just $ liftIO $ do
            ctx <- mkForeignPtr pcre2_compile_context_free $
                pcre2_compile_context_create nullPtr

            forM_ ctxUpds $ \update -> update ctx
            when (xtraOpts /= 0) $ withForeignPtr ctx $ \ctxPtr ->
                pcre2_set_compile_extra_options ctxPtr xtraOpts >>= check (== 0)

            return ctx

    compileEnvERef <- sequence $ do
        ctx <- compileEnvForeignPtr
        f <- recGuard
        Just $ liftIO $ do
            eRef <- newIORef Nothing
            fPtr <- mkFunPtr ctx $ mkRecursionGuard $ \depth _ -> do
                resultOrE <- try $ do
                    f <- evaluate f
                    result <- f $ fromIntegral depth
                    evaluate result
                case resultOrE of
                    Right success -> return $ if success then 0 else 1
                    Left e        -> writeIORef eRef (Just e) >> return 1

            withForeignPtr ctx $ \ctxPtr -> do
                result <- pcre2_set_compile_recursion_guard ctxPtr fPtr nullPtr
                check (== 0) result

            return eRef

    return $ CompileEnv {..}

extractCode :: Text -> CompileEnv -> ExtractOpts Code
extractCode patt (CompileEnv {..}) = do
    opts <- extractCompileOptions

    liftIO $ mkForeignPtr pcre2_code_free $
        Text.useAsPtr patt $ \pattPtr pattCUs ->
        alloca $ \errorCodePtr ->
        alloca $ \errorOffPtr ->
        withForeignOrNullPtr compileEnvForeignPtr $ \ctxPtr -> do
            codePtr <- pcre2_compile
                (castCUs pattPtr)
                (fromIntegral pattCUs)
                opts
                errorCodePtr
                errorOffPtr
                ctxPtr
            when (codePtr == nullPtr) $ do
                -- Re-throw exception (if any) from recursion guard (if any)
                forM_ compileEnvERef $ readIORef >=> mapM_ throwIO
                -- Otherwise throw PCRE2 error
                errorCode <- peek errorCodePtr
                offCUs <- peek errorOffPtr
                throwIO $ Pcre2CompileException errorCode patt offCUs

            return codePtr

extractMatchEnv :: ExtractOpts MatchEnv
extractMatchEnv = do
    ctxUpds <- extractMatchContextUpdates
    matchEnvForeignPtr <- if null ctxUpds
        then return Nothing
        else liftIO $ Just <$> do
            ctx <- mkForeignPtr pcre2_match_context_free $
                pcre2_match_context_create nullPtr

            forM_ ctxUpds $ \update -> update ctx

            return ctx

    matchEnvCallout <- extractCallout
    matchEnvSubCallout <- extractSubCallout

    return $ MatchEnv {..}

data MatchTempEnv = MatchTempEnv {
    matchTempEnvCtx :: Maybe MatchContext,
    matchTempEnvRef :: Maybe (IORef CalloutState)}

-- | Temporarily present a @pcre2_match_context@ for @pcre2_match()@ (or
-- @pcre2_substitute()@) to use.  Depending on various options, resource
-- allocation and deallocation may be required.  For user-defined callouts, the
-- subject itself is required to be available as info.
mkMatchTempEnv :: MatchEnv -> Text -> IO MatchTempEnv
mkMatchTempEnv (MatchEnv {..})
    | null matchEnvCallout && null matchEnvSubCallout = \_ -> return noCallouts
    | otherwise = \subject -> do
        -- Callouts.  To save and inspect state that occurs in callouts
        -- during potentially concurrent matches, we need to create a new state
        -- ref for each match.  This means a new FunPtr to close on it, and that
        -- means a new match context to set it to.
        calloutStateRef <- newIORef $ CalloutState {
            calloutStateException = Nothing,
            calloutStateSubsLog   = IM.empty}
        ctx <- mkForeignPtr pcre2_match_context_free ctxPtrForCallouts

        -- Install C function pointers in the @pcre2_match_context@.  When
        -- dereferenced and called, they will force the user-supplied Haskell
        -- callout functions and their results, catching any exceptions and
        -- saving them.

        -- Install callout, if any
        forM_ matchEnvCallout $ \f -> do
            fPtr <- mkFunPtr ctx $ mkCallout $ \blockPtr _ -> do
                info <- getCalloutInfo subject blockPtr
                resultOrE <- try $ do
                    f <- evaluate f
                    result <- f info
                    evaluate result
                case resultOrE of
                    Right result -> return $ case result of
                        CalloutProceed     -> 0
                        CalloutNoMatchHere -> 1
                        CalloutNoMatch     -> pcre2_ERROR_NOMATCH
                    Left e -> do
                        modifyIORef' calloutStateRef $ \cst -> cst {
                            calloutStateException = Just e}
                        return pcre2_ERROR_CALLOUT
            withForeignPtr ctx $ \ctxPtr ->
                pcre2_set_callout ctxPtr fPtr nullPtr >>= check (== 0)

        -- Install substitution callout, if any
        forM_ matchEnvSubCallout $ \f -> do
            fPtr <- mkFunPtr ctx $ mkCallout $ \blockPtr _ -> do
                info <- getSubCalloutInfo subject blockPtr
                resultOrE <- try $ do
                    f <- evaluate f
                    result <- f info
                    evaluate result
                case resultOrE of
                    Right result -> do
                        modifyIORef' calloutStateRef $ \cst -> cst {
                            calloutStateSubsLog = IM.insert
                                (subCalloutSubsCount info)
                                result
                                (calloutStateSubsLog cst)}
                        return $ case result of
                            SubCalloutAccept ->  0
                            SubCalloutSkip   ->  1
                            SubCalloutAbort  -> -1
                    Left e -> do
                        modifyIORef' calloutStateRef $ \cst -> cst {
                            calloutStateException = Just e}
                        return (-1)
            withForeignPtr ctx $ \ctxPtr -> do
                result <- pcre2_set_substitute_callout ctxPtr fPtr nullPtr
                check (== 0) result

        return $ MatchTempEnv {
            matchTempEnvCtx = Just ctx,
            matchTempEnvRef = Just calloutStateRef}

    where
    noCallouts = MatchTempEnv {
        matchTempEnvCtx = matchEnvForeignPtr,
        matchTempEnvRef = Nothing}
    ctxPtrForCallouts = case matchEnvForeignPtr of
        -- No pre-existing match context, so create one afresh.
        Nothing -> pcre2_match_context_create nullPtr
        -- Pre-existing match context, so copy it.
        Just ctx -> withForeignPtr ctx pcre2_match_context_copy

maybeRethrow :: Maybe (IORef CalloutState) -> IO ()
maybeRethrow = mapM_ $ readIORef >=> mapM_ throwIO . calloutStateException

data SliceRange = SliceRange
    {-# UNPACK #-} !Text.I16
    {-# UNPACK #-} !Text.I16

-- | Does not check if indexes go out of bounds of the ovector.
getOvecEntriesAt :: NonEmpty Int -> MatchData -> IO (NonEmpty SliceRange)
getOvecEntriesAt ns matchData = withForeignPtr matchData $ \matchDataPtr -> do
    ovecPtr <- pcre2_get_ovector_pointer matchDataPtr

    let peekOvec :: Int -> IO Text.I16
        peekOvec = fmap fromIntegral . peekElemOff ovecPtr

    forM ns $ \n -> liftM2 SliceRange
        (peekOvec $ n * 2)
        (peekOvec $ n * 2 + 1)

thinSlice :: Text -> SliceRange -> Text
thinSlice text (SliceRange off offEnd) = text
    & Text.dropWord16 off
    & Text.takeWord16 (offEnd - off)

-- | Also defines heuristic by which substrings are copied or not.
slice :: Text -> SliceRange -> Text
slice text sliceRange
    | Text.length substring > Text.length text `div` 2 = substring
    | otherwise                                        = Text.copy substring
    where
    substring = thinSlice text sliceRange

-- | Helper for @extractAll*@ functions.  Basically, extract all options and
-- produce a function that takes a `Text` subject and does something.
extractAllSubjFun
    :: (Code -> MatchEnv -> CUInt -> Text -> IO a)
    -> Option
    -> Text
    -> IO (Text -> IO a)
extractAllSubjFun mkSubjFun option patt =
    runStateT extractAll (applyOption option) <&> \case
        (subjFun, []) -> subjFun
        _             -> error "BUG! Options not fully extracted"

    where
    extractAll = do
        compileEnv <- extractCompileEnv
        code <- extractCode patt compileEnv
        matchEnv <- extractMatchEnv
        matchOpts <- extractMatchOptions

        return $ mkSubjFun code matchEnv matchOpts

-- | The most general form of a matching function, where all information and
-- auxilliary data structures have been \"compiled\".  It takes a subject and
-- produces a raw result code and match data, to be passed to further validation
-- and inspection.
type Matcher = Text -> IO (CInt, MatchData)

extractAllMatcher :: Option -> Text -> IO Matcher
extractAllMatcher = extractAllSubjFun $ \code matchEnv opts ->
    let matchTempEnvWithSubj = mkMatchTempEnv matchEnv
    in \subject -> withForeignPtr code $ \codePtr -> do
        matchData <- mkForeignPtr pcre2_match_data_free $
            pcre2_match_data_create_from_pattern codePtr nullPtr

        MatchTempEnv {..} <- matchTempEnvWithSubj subject
        result <-
            Text.useAsPtr subject $ \subjPtr subjCUs ->
            withForeignOrNullPtr matchTempEnvCtx $ \ctxPtr ->
            withForeignPtr matchData $ \matchDataPtr -> pcre2_match
                codePtr
                (castCUs subjPtr)
                (fromIntegral subjCUs)
                0
                opts
                matchDataPtr
                ctxPtr
        maybeRethrow matchTempEnvRef

        return (result, matchData)

type Subber = Text -> IO (CInt, Text)

extractAllSubber :: Text -> Option -> Text -> IO Subber
extractAllSubber replacement =
    extractAllSubjFun $ \code firstMatchEnv opts ->
    -- Subber
    \subject ->
    withForeignPtr code $ \codePtr ->
    Text.useAsPtr subject $ \subjPtr subjCUs ->
    Text.useAsPtr replacement $ \replPtr replCUs ->
    alloca $ \outLenPtr -> do
        let checkAndGetOutput :: CInt -> PCRE2_SPTR -> IO (CInt, Text)
            checkAndGetOutput 0      _         = return (0, subject)
            checkAndGetOutput result outBufPtr = do
                check (> 0) result
                outLen <- peek outLenPtr
                out <- Text.fromPtr (castCUs outBufPtr) (fromIntegral outLen)
                return (result, out)

            run :: CUInt -> Ptr Pcre2_match_context -> PCRE2_SPTR -> IO CInt
            run auxOpts ctxPtr outBufPtr = pcre2_substitute
                codePtr
                (castCUs subjPtr)
                (fromIntegral subjCUs)
                0
                (opts .|. auxOpts)
                nullPtr
                ctxPtr
                (castCUs replPtr)
                (fromIntegral replCUs)
                outBufPtr
                outLenPtr

            -- Guess the size of the output to be <= 2x that of the subject.
            initOutLen = Text.length subject * 2

        poke outLenPtr $ fromIntegral initOutLen
        MatchTempEnv {..} <- mkMatchTempEnv firstMatchEnv subject
        firstAttempt <- withForeignOrNullPtr matchTempEnvCtx $ \ctxPtr ->
            allocaArray initOutLen $ \outBufPtr -> do
                result <- run pcre2_SUBSTITUTE_OVERFLOW_LENGTH ctxPtr outBufPtr
                maybeRethrow matchTempEnvRef
                if result == pcre2_ERROR_NOMEMORY
                    then Left <$> case matchTempEnvRef of
                        Nothing  -> return IM.empty
                        Just ref -> calloutStateSubsLog <$> readIORef ref
                    else Right <$> checkAndGetOutput result outBufPtr

        case firstAttempt of
            Right resultAndOutput -> return resultAndOutput
            Left subsLog          -> do
                -- The output was bigger than we guessed.  Try again.
                computedOutLen <- fromIntegral <$> peek outLenPtr
                let finalMatchEnv = firstMatchEnv {
                        -- Do not run capture callouts again.
                        matchEnvCallout = Nothing,
                        -- Do not run any substitution callouts run previously.
                        matchEnvSubCallout =
                            fastFwd <$> matchEnvSubCallout firstMatchEnv}
                    fastFwd f = \info ->
                        case subsLog IM.!? subCalloutSubsCount info of
                            Just result -> return result
                            Nothing     -> f info
                MatchTempEnv {..} <- mkMatchTempEnv finalMatchEnv subject
                withForeignOrNullPtr matchTempEnvCtx $ \ctxPtr ->
                    allocaArray computedOutLen $ \outBufPtr -> do
                        result <- run 0 ctxPtr outBufPtr
                        maybeRethrow matchTempEnvRef
                        checkAndGetOutput result outBufPtr

-- | Helper to create non-Template Haskell API functions.  They all take options
-- and a pattern, and then do something via a 'Matcher'.
withMatcher :: (Matcher -> a) -> Option -> Text -> a
withMatcher f option patt = f $ unsafePerformIO $ extractAllMatcher option patt

-- | Match a pattern to a subject and return a list of captures, or @[]@ if no
-- match.
captures :: Text -> Text -> [Text]
captures = capturesOpt mempty

-- | @captures = capturesOpt mempty@
capturesOpt :: Option -> Text -> Text -> [Text]
capturesOpt option patt = view $ _capturesOpt option patt . to NE.toList

-- | Match a pattern to a subject and return a non-empty list of captures in an
-- `Alternative`, or `empty` if no match.  Typically the @Alternative@ instance
-- will be `Maybe`, but other useful ones exist, notably those of `STM` and of
-- the various parser combinator libraries.
--
-- Note that PCRE2 errors are distinct from match failures and are not
-- represented as `empty`; they are thrown purely as `Pcre2Exception`s.
-- Returning @IO (NonEmpty Text)@ from this function will not enable you to
-- catch them; you must
--
-- > let parseDate = capturesA "(\\d{4})-(\\d{2})-(\\d{2})"
-- > in case parseDate "submitted 2020-10-20" of
-- >     Just (date :| [y, m, d]) -> ...
-- >     Nothing                  -> putStrLn "didn't match"
capturesA :: (Alternative f) => Text -> Text -> f (NonEmpty Text)
capturesA = capturesOptA mempty

-- | @capturesA = capturesOptA mempty@
capturesOptA :: (Alternative f) => Option -> Text -> Text -> f (NonEmpty Text)
capturesOptA option patt = maybe empty pure . preview (_capturesOpt option patt)

-- | Does the pattern match the subject?
matches :: Text -> Text -> Bool
matches = matchesOpt mempty

-- | @matches = matchesOpt mempty@
matchesOpt :: Option -> Text -> Text -> Bool
matchesOpt option patt = has $ _capturesOpt option patt

-- | Match a pattern to a subject and return only the portion that matched, i.e.
-- the 0th capture.
match :: (Alternative f) => Text -> Text -> f Text
match = matchOpt mempty

matchOpt :: (Alternative f) => Option -> Text -> Text -> f Text
matchOpt = withMatcher $ \matcher ->
    let _match = _capturesInternal matcher (Just $ 0 :| []) . _headNE
    in maybe empty pure . preview _match

sub
    :: Text -- ^ pattern
    -> Text -- ^ replacement
    -> Text -- ^ subject
    -> Text -- ^ result
sub = subOpt mempty

gsub :: Text -> Text -> Text -> Text
gsub = subOpt SubGlobal

subOpt :: Option -> Text -> Text -> Text -> Text
subOpt option patt replacement = snd . unsafePerformIO . subber where
    subber = unsafePerformIO $ extractAllSubber replacement option patt

-- | Given a pattern, produce an affine traversal (0 or 1 targets) that focuses
-- from a subject to a potential non-empty list of captures.
--
-- Substitution works in the following way:  If a capture is set such that the
-- new `Text` is not equal to the old one, a substitution occurs, otherwise it
-- doesn\'t.  This matters in cases where a capture encloses another
-- capture&mdash;notably, _all_ parenthesized captures are enclosed by the 0th
-- capture, the region of the subject matched by the whole pattern.
--
-- > let threeAndMiddle = _captures ". (.) ."
-- > print $ set threeAndMiddle ("A A A" :| ["B"]) "A A A" -- "A B A"
-- > print $ set threeAndMiddle ("A B A" :| ["A"]) "A A A" -- "A B A"
--
-- Changing multiple overlapping captures is unsupported and won\'t do what you
-- want.
--
-- If the list becomes longer for some reason, the extra elements are ignored;
-- if it\'s shortened, the absent elements are considered to be unchanged.
--
-- It's recommended that the list be modified capture-wise, using @ix@.
--
-- > let madlibs = _captures "(\\w+) my (\\w+)"
-- >
-- > print $ "Well bust my buttons!" &~ do
-- >     zoom madlibs $ do
-- >         ix 1 . _head .= 'd'
-- >         ix 2 %= Text.reverse
-- >     _last .= '?'
-- >
-- > -- "Well dust my snottub?"
_captures :: Text -> Traversal' Text (NonEmpty Text)
_captures = _capturesOpt mempty

_capturesOpt :: Option -> Text -> Traversal' Text (NonEmpty Text)
_capturesOpt = withMatcher $ \matcher -> _capturesInternal matcher Nothing

predictCaptureNames :: Option -> Text -> IO [Maybe Text]
predictCaptureNames option patt = do
    code <- evalStateT
        (extractCompileEnv >>= extractCode patt)
        (applyOption option)

    withForeignPtr code getCaptureNames

----------------- From Compile.hs ----------------------------------------------

-- | NOTE: The 0th capture is always named Nothing.
getCaptureNames :: Ptr Pcre2_code -> IO [Maybe Text]
getCaptureNames codePtr = do
    nameCount <- getCodeInfo @CUInt codePtr pcre2_INFO_NAMECOUNT
    nameEntrySize <- getCodeInfo @CUInt codePtr pcre2_INFO_NAMEENTRYSIZE
    nameTable <- getCodeInfo @PCRE2_SPTR codePtr pcre2_INFO_NAMETABLE

    -- Can't do [0 .. nameCount - 1] because it underflows when nameCount == 0
    let indexes = takeWhile (< nameCount) [0 ..]
    names <- fmap IM.fromList $ forM indexes $ \i -> do
        let entryPtr = nameTable `advancePtr` fromIntegral (i * nameEntrySize)
            groupNamePtr = entryPtr `advancePtr` 1
        groupNumber <- peek entryPtr
        groupNameLen <- lengthArray0 0 groupNamePtr
        groupName <- Text.fromPtr
            (castCUs groupNamePtr)
            (fromIntegral groupNameLen)
        return (fromIntegral groupNumber, groupName)

    captureCount <- getCodeInfo @CUInt codePtr pcre2_INFO_CAPTURECOUNT

    return $ map (names IM.!?) [0 .. fromIntegral captureCount]

getCodeInfo :: (Storable a) => Ptr Pcre2_code -> CUInt -> IO a
getCodeInfo codePtr what = alloca $ \wherePtr -> do
    pcre2_pattern_info codePtr what wherePtr >>= check (== 0)
    peek wherePtr

---------------------------- From Option.hs ------------------------------------

instance Semigroup Option where
    opt0 <> opt1 = case listOptions opt0 ++ listOptions opt1 of
        [opt] -> opt
        opts  -> Options opts

instance Monoid Option where
    mempty = Options []

listOptions :: Option -> [Option]
listOptions (Options opts) = opts
listOptions opt            = [opt]

data Option
    = Options [Option]
    -- Compile options
    | Anchored
    | AllowEmptyClass
    | AltBsuxLegacy
    | AltCircumflex
    | AltVerbNames
    | AutoCallout
    | Caseless
    | DollarEndOnly
    | DotAll
    | DupNames
    | EndAnchored
    | Extended
    | ExtendedMore
    | FirstLine
    | Literal
    | MatchUnsetBackRef
    | Multiline
    | NeverBackslashC
    | NeverUcp
    | NoAutoCapture
    | NoAutoPossess
    | NoDotStarAnchor
    | NoStartOptimize
    | Ucp
    | Ungreedy
    | UseOffsetLimit
    | Utf
    -- Compile context options
    | Bsr Bsr
    | AltBsux
    | BadEscapeIsLiteral
    | EscapedCrIsLf
    | MatchLine
    | MatchWord
    | MaxPatternLength Int
    | Newline Newline
    | ParensNestLimit Int
    -- Compile recursion guard
    | UnsafeCompileRecGuard (Int -> IO Bool)
    -- Match options
    | NotBol
    | NotEol
    | NotEmpty
    | NotEmptyAtStart
    | PartialHard
    | PartialSoft
    -- Substitute options
    | SubReplacementOnly
    | SubGlobal
    | SubLiteral
    | SubUnknownEmpty
    -- Callout
    | UnsafeCallout (CalloutInfo -> IO CalloutResult)
    -- Substition callout
    | UnsafeSubCallout (SubCalloutInfo -> IO SubCalloutResult)
    -- Match context options
    | OffsetLimit Int
    | HeapLimit Int
    | MatchLimit Int
    | DepthLimit Int

data SubCalloutInfo
    = SubCalloutInfo {
        subCalloutSubsCount   :: Int,
        subCalloutCaptures    :: NonEmpty (Maybe Text),
        subCalloutSubject     :: Text,
        subCalloutReplacement :: Text}
    deriving (Show, Eq)

foreign import ccall "wrapper" mkRecursionGuard
    :: (CUInt -> Ptr a -> IO CInt)
    -> IO (FunPtr (CUInt -> Ptr a -> IO CInt))

foreign import ccall "wrapper" mkCallout
    :: (Ptr block -> Ptr a -> IO CInt)
    -> IO (FunPtr (Ptr block -> Ptr a -> IO CInt))

data CalloutInfo
    = CalloutInfo {
        calloutIndex       :: CalloutIndex,
        calloutCaptures    :: NonEmpty (Maybe Text),
        calloutSubject     :: Text,
        calloutMark        :: Maybe Text,
        calloutIsFirst     :: Bool,
        calloutBacktracked :: Bool}
    deriving (Show, Eq)

data CalloutIndex
    = CalloutNumber Int
    | CalloutName Text
    | CalloutPatternPos Int Int
    deriving (Show, Eq)

data CalloutResult
    = CalloutProceed
    | CalloutNoMatchHere
    | CalloutNoMatch
    deriving (Show, Eq)

data SubCalloutResult
    = SubCalloutAccept
    | SubCalloutSkip
    | SubCalloutAbort
    deriving (Show, Eq)

getCalloutInfo :: Text -> Ptr Pcre2_callout_block -> IO CalloutInfo
getCalloutInfo subject blockPtr = do
    calloutIndex <- do
        str <- pcre2_callout_block_callout_string blockPtr
        if str == nullPtr
            then pcre2_callout_block_callout_number blockPtr >>= \case
                -- Auto callout
                255 -> liftM2 CalloutPatternPos pattPos itemLen where
                    pattPos = intVia pcre2_callout_block_pattern_position
                    itemLen = intVia pcre2_callout_block_next_item_length
                    intVia getter = fromIntegral <$> getter blockPtr
                -- Numerical callout
                number -> return $ CalloutNumber $ fromIntegral number
            else do
                -- String callout
                len <- pcre2_callout_block_callout_string_length blockPtr
                CalloutName <$> Text.fromPtr (castCUs str) (fromIntegral len)

    let calloutSubject = subject

    calloutCaptures <- do
        ovecPtr <- pcre2_callout_block_offset_vector blockPtr
        top <- pcre2_callout_block_capture_top blockPtr
        forM (0 :| [1 .. fromIntegral top - 1]) $ \n -> do
            start <- peekElemOff ovecPtr $ n * 2
            if start == pcre2_UNSET
                then return Nothing
                else Just <$> do
                    end <- peekElemOff ovecPtr $ n * 2 + 1
                    return $ slice calloutSubject $ SliceRange
                        (fromIntegral start)
                        (fromIntegral end)

    calloutMark <- do
        ptr <- pcre2_callout_block_mark blockPtr
        if ptr == nullPtr
            then return Nothing
            else Just <$> do
                -- TODO Replace this with a more obviously best way to slurp a
                -- zero-terminated region of memory into a `Text`, given
                -- whatever the pcre2callout spec means by "zero-terminated".
                len <- fix1 0 $ \go off -> peekElemOff ptr off >>= \case
                    0 -> return off
                    _ -> go $ off + 1
                Text.fromPtr (castCUs ptr) (fromIntegral len)

    flags <- pcre2_callout_block_callout_flags blockPtr
    let calloutIsFirst = flags .&. pcre2_CALLOUT_STARTMATCH /= 0
        calloutBacktracked = flags .&. pcre2_CALLOUT_BACKTRACK /= 0

    return $ CalloutInfo {..}

getSubCalloutInfo
    :: Text -> Ptr Pcre2_substitute_callout_block -> IO SubCalloutInfo
getSubCalloutInfo subject blockPtr = do
    subCalloutSubsCount <-
        fromIntegral <$> pcre2_substitute_callout_block_subscount blockPtr

    subCalloutCaptures <- do
        ovecPtr <- pcre2_substitute_callout_block_ovector blockPtr
        ovecCount <- pcre2_substitute_callout_block_oveccount blockPtr
        forM (0 :| [1 .. fromIntegral ovecCount - 1]) $ \n -> do
            start <- peekElemOff ovecPtr $ n * 2
            if start == pcre2_UNSET
                then return Nothing
                else Just <$> do
                    end <- peekElemOff ovecPtr $ n * 2 + 1
                    return $ slice subject $ SliceRange
                        (fromIntegral start)
                        (fromIntegral end)

    let subCalloutSubject = subject

    subCalloutReplacement <- do
        outPtr <- pcre2_substitute_callout_block_output blockPtr
        offsetsPtr <- pcre2_substitute_callout_block_output_offsets blockPtr
        [start, end] <- mapM (peekElemOff offsetsPtr) [0, 1]
        Text.fromPtr
            (castCUs $ advancePtr outPtr $ fromIntegral start)
            (fromIntegral $ end - start)

    return $ SubCalloutInfo {..}

-- | Equivalent to @flip fix@.
--
-- Used to express a recursive function of one argument that is called only once
-- on an initial value:
--
-- > let go x = ... in go x0
--
-- as:
--
-- > fix1 x0 $ \go x -> ...
fix1 :: a -> ((a -> b) -> a -> b) -> b
fix1 x f = fix f x

-- | Like `fix1`, but for a function of two arguments.
fix2 :: a -> b -> ((a -> b -> t3) -> a -> b -> t3) -> t3
fix2 x y f = fix f x y

applyOption :: Option -> [AppliedOption]
applyOption = \case
    Options opts -> opts >>= applyOption

    -- CompileOption
    Anchored          -> [CompileOption pcre2_ANCHORED]
    AllowEmptyClass   -> [CompileOption pcre2_ALLOW_EMPTY_CLASS]
    AltBsuxLegacy     -> [CompileOption pcre2_ALT_BSUX]
    AltCircumflex     -> [CompileOption pcre2_ALT_CIRCUMFLEX]
    AltVerbNames      -> [CompileOption pcre2_ALT_VERBNAMES]
    AutoCallout       -> [CompileOption pcre2_AUTO_CALLOUT]
    Caseless          -> [CompileOption pcre2_CASELESS]
    DollarEndOnly     -> [CompileOption pcre2_DOLLAR_ENDONLY]
    DotAll            -> [CompileOption pcre2_DOTALL]
    DupNames          -> [CompileOption pcre2_DUPNAMES]
    EndAnchored       -> [CompileOption pcre2_ENDANCHORED]
    Extended          -> [CompileOption pcre2_EXTENDED]
    ExtendedMore      -> [CompileOption pcre2_EXTENDED_MORE]
    FirstLine         -> [CompileOption pcre2_FIRSTLINE]
    Literal           -> [CompileOption pcre2_LITERAL]
    MatchUnsetBackRef -> [CompileOption pcre2_MATCH_UNSET_BACKREF]
    Multiline         -> [CompileOption pcre2_MULTILINE]
    NeverBackslashC   -> [CompileOption pcre2_NEVER_BACKSLASH_C]
    NeverUcp          -> [CompileOption pcre2_NEVER_UCP]
    NoAutoCapture     -> [CompileOption pcre2_NO_AUTO_CAPTURE]
    NoAutoPossess     -> [CompileOption pcre2_NO_AUTO_POSSESS]
    NoDotStarAnchor   -> [CompileOption pcre2_NO_DOTSTAR_ANCHOR]
    NoStartOptimize   -> [CompileOption pcre2_NO_START_OPTIMIZE]
    Ucp               -> [CompileOption pcre2_UCP]
    Ungreedy          -> [CompileOption pcre2_UNGREEDY]
    UseOffsetLimit    -> [CompileOption pcre2_USE_OFFSET_LIMIT]
    Utf               -> [CompileOption pcre2_UTF]

    -- ExtraCompileOption
    AltBsux            -> [CompileExtraOption pcre2_EXTRA_ALT_BSUX]
    BadEscapeIsLiteral -> [CompileExtraOption pcre2_EXTRA_BAD_ESCAPE_IS_LITERAL]
    EscapedCrIsLf      -> [CompileExtraOption pcre2_EXTRA_ESCAPED_CR_IS_LF]
    MatchLine          -> [CompileExtraOption pcre2_EXTRA_MATCH_LINE]
    MatchWord          -> [CompileExtraOption pcre2_EXTRA_MATCH_WORD]

    -- CompileContextOption
    Bsr bsr -> unary
        CompileContextOption pcre2_set_bsr (bsrToC bsr)
    MaxPatternLength len -> unary
        CompileContextOption pcre2_set_max_pattern_length (fromIntegral len)
    Newline newline -> unary
        CompileContextOption pcre2_set_newline (newlineToC newline)
    ParensNestLimit limit -> unary
        CompileContextOption pcre2_set_parens_nest_limit (fromIntegral limit)

    -- CompileRecGuardOption
    UnsafeCompileRecGuard f -> [CompileRecGuardOption f]

    -- MatchOption
    NotBol             -> [MatchOption pcre2_NOTBOL]
    NotEol             -> [MatchOption pcre2_NOTEOL]
    NotEmpty           -> [MatchOption pcre2_NOTEMPTY]
    NotEmptyAtStart    -> [MatchOption pcre2_NOTEMPTY_ATSTART]
    PartialHard        -> [MatchOption pcre2_PARTIAL_HARD]
    PartialSoft        -> [MatchOption pcre2_PARTIAL_SOFT]
    SubReplacementOnly -> [MatchOption pcre2_SUBSTITUTE_REPLACEMENT_ONLY]
    SubGlobal          -> [MatchOption pcre2_SUBSTITUTE_GLOBAL]
    SubLiteral         -> [MatchOption pcre2_SUBSTITUTE_LITERAL]
    SubUnknownEmpty    -> [
        MatchOption pcre2_SUBSTITUTE_UNKNOWN_UNSET,
        MatchOption pcre2_SUBSTITUTE_UNSET_EMPTY]

    -- CalloutOption
    UnsafeCallout f -> [CalloutOption f]

    -- SubCalloutOption
    UnsafeSubCallout f -> [SubCalloutOption f]

    -- MatchContextOption
    OffsetLimit limit -> applyOption UseOffsetLimit ++ unary
        MatchContextOption pcre2_set_offset_limit (fromIntegral limit)
    HeapLimit limit -> unary
        MatchContextOption pcre2_set_heap_limit (fromIntegral limit)
    MatchLimit limit -> unary
        MatchContextOption pcre2_set_match_limit (fromIntegral limit)
    DepthLimit limit -> unary
        MatchContextOption pcre2_set_depth_limit (fromIntegral limit)

    where
    unary ctor f x = (: []) $ ctor $ \ctx -> withForeignPtr ctx $ \ctxPtr ->
        f ctxPtr x >>= check (== 0)

data AppliedOption
    = CompileOption CUInt
    | CompileExtraOption CUInt
    | CompileContextOption (CompileContext -> IO ())
    | CompileRecGuardOption (Int -> IO Bool)
    | MatchOption CUInt
    | CalloutOption (CalloutInfo -> IO CalloutResult)
    | SubCalloutOption (SubCalloutInfo -> IO SubCalloutResult)
    | MatchContextOption (MatchContext -> IO ())

extractOpts :: (AppliedOption -> Either a AppliedOption) -> ExtractOpts [a]
extractOpts discrim = state $ partitionEithers . map discrim

extractCompileContextUpdates :: ExtractOpts [CompileContext -> IO ()]
extractCompileContextUpdates = extractOpts $ \case
    CompileContextOption update -> Left update
    opt                         -> Right opt

extractCompileExtraOptions :: ExtractOpts CUInt
extractCompileExtraOptions = fmap (foldl' (.|.) 0) $ extractOpts $ \case
    CompileExtraOption flag -> Left flag
    opt                     -> Right opt

extractRecursionGuard :: ExtractOpts (Maybe (Int -> IO Bool))
extractRecursionGuard = fmap safeLast $ extractOpts $ \case
    CompileRecGuardOption f -> Left f
    opt                     -> Right opt

extractCompileOptions :: ExtractOpts CUInt
extractCompileOptions = fmap (foldl' (.|.) 0) $ extractOpts $ \case
    CompileOption flag -> Left flag
    opt                -> Right opt

extractMatchContextUpdates :: ExtractOpts [MatchContext -> IO ()]
extractMatchContextUpdates = extractOpts $ \case
    MatchContextOption update -> Left update
    opt                       -> Right opt

extractCallout :: ExtractOpts (Maybe (CalloutInfo -> IO CalloutResult))
extractCallout = fmap safeLast $ extractOpts $ \case
    CalloutOption f -> Left f
    opt             -> Right opt

extractSubCallout :: ExtractOpts (Maybe (SubCalloutInfo -> IO SubCalloutResult))
extractSubCallout = fmap safeLast $ extractOpts $ \case
    SubCalloutOption f -> Left f
    opt                -> Right opt

extractMatchOptions :: ExtractOpts CUInt
extractMatchOptions = fmap (foldl' (.|.) 0) $ extractOpts $ \case
    MatchOption flag -> Left flag
    opt              -> Right opt

----------------------------- From Captures.hs ---------------------------------

-- | A wrapper around a list of captures that carries additional type-level
-- information about the number and names of those captures.
newtype Captures (info :: CapturesInfo) = Captures (NonEmpty Text)

-- | The kind of that information.
--
-- This definition is not part of the public API and may change without warning!
type CapturesInfo = (Nat, [(Symbol, Nat)])

-- | Look up the number of a capture at compile time, either by number or by
-- name.  Throw a helpful 'TypeError' if the index doesn\'t exist.
type family CaptNum (i :: k) (info :: CapturesInfo) :: Nat where
    CaptNum (number :: Nat) '(hi, _) =
        If (CmpNat number 0 == 'LT || CmpNat number hi == 'GT)
            {-then-} (TypeError
                (TypeLits.Text "No capture numbered " :<>: ShowType number))
            {-else-} number

    CaptNum (name :: Symbol) '(_, '(name, number) ': _) = number
    CaptNum (name :: Symbol) '(hi, _ ': kvs) = 1 + CaptNum name '(hi, kvs)
    CaptNum (name :: Symbol) _ = TypeError
        (TypeLits.Text "No capture named " :<>: ShowType name)

    CaptNum _ _ = TypeError
        (TypeLits.Text "Capture index must be a number (Nat) or name (Symbol)")

capture :: forall i info number. (CaptNum i info ~ number, KnownNat number) =>
    Captures info -> Text
capture = view $ _capture @i

-- | The most general form of a matching/substitution function.
--
-- When any capture is forced, all captures are forced in order to GC C data
-- more promptly.  When we need _some_ captures but not _all_ captures, we can
-- pass in a whitelist of the numbers of captures we want.
--
-- Internal only!  Users should not (have to) know about `Matcher`.
_capturesInternal
    :: Matcher
    -> Maybe (NonEmpty Int)
    -> Traversal' Text (NonEmpty Text)
_capturesInternal matcher whitelist f subject
    | result == pcre2_ERROR_NOMATCH = pure subject
    | result <= 0                   = throw $ Pcre2Exception result
    | otherwise                     = f cs <&> \cs' ->
        -- Swag foldl-as-foldr to create only as many segments as we need to
        -- stitch back together and no more.
        let triples = ovecEntries `NE.zip` cs `NE.zip` cs'
        in Text.concat $ foldr mkSegments termSegments triples 0

    where

    (result, matchData) = unsafePerformIO $ matcher subject
    ovecEntries = unsafePerformIO $ getOvecEntriesAt ns matchData
    cs = unsafePerformIO $ forM ovecEntries $ evaluate . slice subject
    ns = fromMaybe (0 :| [1 .. fromIntegral result - 1]) whitelist

    mkSegments ((SliceRange off offEnd, c), c') r prevOffEnd
        -- This substring is unchanged.  Keep going without making cuts.
        | c == c'   = r prevOffEnd
        | otherwise =
            -- Emit the subject up until here, and the new substring, and keep
            -- going, remembering where we are now.
            thinSlice subject (SliceRange prevOffEnd off) : c' : r offEnd
    termSegments off =
        let offEnd = fromIntegral $ Text.length subject
        -- If the terminal segment is empty, omit it altogether.  That way,
        -- `Text.concat` can just return the subject without copying anything in
        -- cases where no substring is changed.
        in [thinSlice subject (SliceRange off offEnd) | off /= offEnd]

_capture :: forall i info number. (CaptNum i info ~ number, KnownNat number) =>
    Lens' (Captures info) Text
_capture f (Captures cs) =
    let (ls, c : rs) = NE.splitAt (fromInteger $ natVal @number Proxy) cs
    in f c <&> \c' -> Captures $ NE.fromList $ ls ++ c' : rs

-- Lens types and utilities

type Lens'      s a = forall f. (Functor f)     => (a -> f a) -> s -> f s
type Traversal' s a = forall f. (Applicative f) => (a -> f a) -> s -> f s

_headNE :: Lens' (NonEmpty a) a
_headNE f (x :| xs) = f x <&> \x' -> x' :| xs

preview l = getFirst . getConst . l (Const . First . Just)
view l = getConst . l Const
to k f = Const . getConst . f . k
has l = getAny . getConst . l (\_ -> Const $ Any True)
over l f = runIdentity . l (Identity . f)

------------------------ Common.hs ---------------------------------------------

type CompileContext = ForeignPtr Pcre2_compile_context
type MatchContext   = ForeignPtr Pcre2_match_context
type Code           = ForeignPtr Pcre2_code
type MatchData      = ForeignPtr Pcre2_match_data

data SomePcre2Exception = forall e. (Exception e) => SomePcre2Exception e
instance Show SomePcre2Exception where
    show (SomePcre2Exception e) = show e
instance Exception SomePcre2Exception

newtype Pcre2Exception = Pcre2Exception CInt
instance Show Pcre2Exception where
    show (Pcre2Exception x) = Text.unpack $ getErrorMessage x
instance Exception Pcre2Exception where
    toException = toException . SomePcre2Exception
    fromException = fromException >=> \(SomePcre2Exception e) -> cast e

data Pcre2CompileException = Pcre2CompileException !CInt !Text !PCRE2_SIZE
instance Show Pcre2CompileException where
    show (Pcre2CompileException x patt offset) = intercalate "\n" $ [
        "pcre2_compile: " ++ Text.unpack (getErrorMessage x),
        replicate tab ' ' ++ Text.unpack patt] ++
        [replicate (tab + offset') ' ' ++ "^" | offset' < Text.length patt]
        where
        tab = 20
        offset' = fromIntegral offset
instance Exception Pcre2CompileException where
    toException = toException . SomePcre2Exception
    fromException = fromException >=> \(SomePcre2Exception e) -> cast e

getErrorMessage :: CInt -> Text
getErrorMessage errorCode = unsafePerformIO $ do
    let bufCUs = 120
    allocaBytes (bufCUs * 2) $ \bufPtr -> do
        cus <- pcre2_get_error_message errorCode bufPtr (fromIntegral bufCUs)
        Text.fromPtr (castCUs bufPtr) (fromIntegral cus)

check :: (CInt -> Bool) -> CInt -> IO ()
check p x = unless (p x) $ throwIO $ Pcre2Exception x

data Bsr
    = BsrAnyCrlf
    | BsrUnicode
    deriving (Eq, Show)

bsrFromC :: CUInt -> Bsr
bsrFromC x
    | x == pcre2_BSR_UNICODE = BsrUnicode
    | x == pcre2_BSR_ANYCRLF = BsrAnyCrlf
    | otherwise              = error $ "bsrFromC: bad value " ++ show x

bsrToC :: Bsr -> CUInt
bsrToC BsrUnicode = pcre2_BSR_UNICODE
bsrToC BsrAnyCrlf = pcre2_BSR_ANYCRLF

data Newline
    = NewlineCr
    | NewlineLf
    | NewlineCrlf
    | NewlineAny
    | NewlineAnyCrlf
    | NewlineNul
    deriving (Eq, Show)

newlineFromC :: CUInt -> Newline
newlineFromC x
    | x == pcre2_NEWLINE_CR      = NewlineCr
    | x == pcre2_NEWLINE_LF      = NewlineLf
    | x == pcre2_NEWLINE_CRLF    = NewlineCrlf
    | x == pcre2_NEWLINE_ANY     = NewlineAny
    | x == pcre2_NEWLINE_ANYCRLF = NewlineAnyCrlf
    | x == pcre2_NEWLINE_NUL     = NewlineNul
    | otherwise                  = error $ "newlineFromC: bad value " ++ show x

newlineToC :: Newline -> CUInt
newlineToC NewlineCr      = pcre2_NEWLINE_CR
newlineToC NewlineLf      = pcre2_NEWLINE_LF
newlineToC NewlineCrlf    = pcre2_NEWLINE_CRLF
newlineToC NewlineAny     = pcre2_NEWLINE_ANY
newlineToC NewlineAnyCrlf = pcre2_NEWLINE_ANYCRLF
newlineToC NewlineNul     = pcre2_NEWLINE_NUL

-- | Probably unnecessary, but unrestricted 'castPtr' feels dangerous.
class CastCUs a b | a -> b where
    castCUs :: Ptr a -> Ptr b
    castCUs = castPtr
    {-# INLINE castCUs #-}
instance CastCUs CUShort Word16
instance CastCUs Word16 CUShort

-------------------------------- Config.hs -------------------------------------

getConfigNumeric :: CUInt -> CUInt
getConfigNumeric what = unsafePerformIO $ alloca $ \ptr -> do
    pcre2_config what ptr
    peek ptr

getConfigString :: CUInt -> Maybe Text
getConfigString what = unsafePerformIO $ do
    len <- pcre2_config what nullPtr
    if len == pcre2_ERROR_BADOPTION
        then return Nothing
        -- FIXME Do we really need "+ 1" here?
        else fmap Just $ allocaBytes (fromIntegral (len + 1) * 2) $ \ptr -> do
            pcre2_config what ptr
            Text.fromPtr ptr (fromIntegral len - 1)

defaultBsr :: Bsr
defaultBsr = bsrFromC $ getConfigNumeric pcre2_CONFIG_BSR

compiledWidths :: [Int]
compiledWidths =
    let bitmap = getConfigNumeric pcre2_CONFIG_COMPILED_WIDTHS
    in [w | (b, w) <- [(1, 8), (2, 16), (4, 32)], b .&. bitmap /= 0]

defaultDepthLimit :: Int
defaultDepthLimit = fromIntegral $ getConfigNumeric pcre2_CONFIG_DEPTHLIMIT

defaultHeapLimit :: Int
defaultHeapLimit = fromIntegral $ getConfigNumeric pcre2_CONFIG_HEAPLIMIT

supportsJit :: Bool
supportsJit = getConfigNumeric pcre2_CONFIG_JIT == 1

jitTarget :: Maybe Text
jitTarget = getConfigString pcre2_CONFIG_JITTARGET

linkSize :: Int
linkSize = fromIntegral $ getConfigNumeric pcre2_CONFIG_LINKSIZE

defaultMatchLimit :: Int
defaultMatchLimit = fromIntegral $ getConfigNumeric pcre2_CONFIG_MATCHLIMIT

defaultNewline :: Newline
defaultNewline = newlineFromC $ getConfigNumeric pcre2_CONFIG_NEWLINE

neverBackslashC :: Bool
neverBackslashC = getConfigNumeric pcre2_CONFIG_NEVER_BACKSLASH_C == 1

parensLimit :: Int
parensLimit = fromIntegral $ getConfigNumeric pcre2_CONFIG_PARENSLIMIT

tablesLength :: Int
tablesLength = fromIntegral $ getConfigNumeric pcre2_CONFIG_TABLES_LENGTH

unicodeVersion :: Text
unicodeVersion = fromJust $ getConfigString pcre2_CONFIG_UNICODE_VERSION

supportsUnicode :: Bool
supportsUnicode = getConfigNumeric pcre2_CONFIG_UNICODE == 1

version :: Text
version = fromJust $ getConfigString pcre2_CONFIG_VERSION