{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module:      Trace.Hpc.Codecov
-- Copyright:   (c) 2014 Guillaume Nargeot
-- License:     BSD3
-- Maintainer:  Guillaume Nargeot <guillaume+hackage@nargeot.com>
-- Stability:   experimental
--
-- Functions for converting and sending hpc output to codecov.io.

module Trace.Hpc.Codecov ( generateCodecovFromTix ) where

import           Data.Aeson
import           Data.Aeson.Types ()
import           Data.List
import qualified Data.Map.Strict as M
import           System.Exit (exitFailure)
import           Trace.Hpc.Codecov.Config
import           Trace.Hpc.Codecov.Lix
import           Trace.Hpc.Codecov.Paths
import           Trace.Hpc.Codecov.Types
import           Trace.Hpc.Codecov.Util
import           Trace.Hpc.Mix
import           Trace.Hpc.Tix
import           Trace.Hpc.Util

type ModuleCoverageData = (
    String,    -- file source code
    Mix,       -- module index data
    [Integer]) -- tixs recorded by hpc

type TestSuiteCoverageData = M.Map FilePath ModuleCoverageData

-- single file coverage data in the format defined by codecov.io
type SimpleCoverage = [CoverageValue]

-- Is there a way to restrict this to only Number and Null?
type CoverageValue = Value

type LixConverter = Lix -> SimpleCoverage

strictConverter :: LixConverter
strictConverter = map $ \lix -> case lix of
    Full       -> Number 1
    Partial    -> Number 0
    None       -> Number 0
    Irrelevant -> Null

looseConverter :: LixConverter
looseConverter = map $ \lix -> case lix of
    Full       -> Number 1
    Partial    -> Bool True
    None       -> Number 0
    Irrelevant -> Null

toSimpleCoverage :: LixConverter -> Int -> [CoverageEntry] -> SimpleCoverage
toSimpleCoverage convert lineCount = (:) Null . convert . toLix lineCount

getExprSource :: [String] -> MixEntry -> [String]
getExprSource source (hpcPos, _) = subSubSeq startCol endCol subLines
    where subLines = subSeq startLine endLine source
          startLine = startLine' - 1
          startCol = startCol' - 1
          (startLine', startCol', endLine, endCol) = fromHpcPos hpcPos

-- TODO possible renaming to "getModuleCoverage"
coverageToJson :: LixConverter -> ModuleCoverageData -> SimpleCoverage
coverageToJson converter (source, mix, tixs) = simpleCoverage
    where simpleCoverage = toSimpleCoverage converter lineCount mixEntryTixs
          lineCount = length $ lines source
          mixEntryTixs = zip3 mixEntries tixs (map getExprSource' mixEntries)
          Mix _ _ _ _ mixEntries = mix
          getExprSource' = getExprSource $ lines source

toCodecovJson :: LixConverter -> TestSuiteCoverageData -> Value
toCodecovJson converter testSuiteCoverageData = object [
    "coverage" .= toJsonCoverageMap testSuiteCoverageData]
    where toJsonCoverageMap = M.map (coverageToJson converter)

mergeModuleCoverageData :: ModuleCoverageData -> ModuleCoverageData -> ModuleCoverageData
mergeModuleCoverageData (source, mix, tixs1) (_, _, tixs2) =
    (source, mix, zipWith (+) tixs1 tixs2)

mergeCoverageData :: [TestSuiteCoverageData] -> TestSuiteCoverageData
mergeCoverageData = foldr1 (M.unionWith mergeModuleCoverageData)

readMix' :: String -> TixModule -> IO Mix
readMix' name tix = readMix [getMixPath name tix] (Right tix)

-- | Create a list of coverage data from the tix input
readCoverageData :: String                   -- ^ test suite name
                 -> [String]                 -- ^ excluded source folders
                 -> IO TestSuiteCoverageData -- ^ coverage data list
readCoverageData testSuiteName excludeDirPatterns = do
    tixPath <- getTixPath testSuiteName
    mtix <- readTix tixPath
    case mtix of
        Nothing -> error ("Couldn't find the file " ++ tixPath) >> exitFailure
        Just (Tix tixs) -> do
            mixs <- mapM (readMix' testSuiteName) tixs
            let files = map filePath mixs
            sources <- mapM readFile files
            let coverageDataList = zip4 files sources mixs (map tixModuleTixs tixs)
            let filteredCoverageDataList = filter sourceDirFilter coverageDataList
            return $ M.fromList $ map toFirstAndRest filteredCoverageDataList
            where filePath (Mix fp _ _ _ _) = fp
                  sourceDirFilter = not . matchAny excludeDirPatterns . fst4

-- | Generate codecov json formatted code coverage from hpc coverage data
generateCodecovFromTix :: Config   -- ^ codecov-haskell configuration
                       -> IO Value -- ^ code coverage result in json format
generateCodecovFromTix config = do
    testSuitesCoverages <- mapM (`readCoverageData` excludedDirPatterns) testSuiteNames
    return $ toCodecovJson converter $ mergeCoverageData testSuitesCoverages
    where excludedDirPatterns = excludedDirs config
          testSuiteNames = testSuites config
          converter = case coverageMode config of
              StrictlyFullLines -> strictConverter
              AllowPartialLines -> looseConverter
