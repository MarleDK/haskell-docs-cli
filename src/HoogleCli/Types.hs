module HoogleCli.Types where

import Data.Text (Text)
import Data.List.NonEmpty (NonEmpty)

import qualified Data.Text as Text
import qualified Hoogle

type Url = String

-- | Appears at the end of a url after a pound sign, pointing the element to
-- focus on.
--    https://hackage.haskell.org/package/hoogle-5.0.18.1/docs/Hoogle.html#t:Target
--                                                                         ^^^^^^^^
type Anchor = Text

dropAnchor :: Url -> Url
dropAnchor = takeWhile (/= '#')

takeAnchor :: MonadFail m => Url -> m Anchor
takeAnchor url = case drop 1 $ dropWhile (/= '#') url of
  [] -> fail "no anchor"
  xs -> return $ Text.pack xs

type TargetGroup = NonEmpty Hoogle.Target

data DeclUrl = DeclUrl ModuleUrl Anchor
  deriving Show

-- | Link to an item in a src page
data SourceLink = SourceLink Url Anchor
  deriving (Show)

newtype ModuleUrl = ModuleUrl Url
  deriving (Show)

-- | Url to a Haddock package page
newtype PackageUrl = PackageUrl Url
  deriving (Show)

type FileName = String

type FileContent = Text

newtype RelativeUrl = RelativeUrl Text

data FileInfo = FileInfo
  { fName :: FileName
  , fLine :: Maybe Int
  , fContent :: FileContent
  }