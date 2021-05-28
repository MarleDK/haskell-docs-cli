{-# LANGUAGE LambdaCase #-}
module HoogleCli.Haddock
  ( Html
  , HtmlPage
  , Module(..)
  , Declaration(..)
  , parseHtmlDocument
  , parseModuleDocs
  , prettyHtml
  , numbered
  , parseHoogleHtml
  , sourceLinks
  , fileInfo
  )
  where

-- | Functions to parse and display Haddock HTML

import HoogleCli.Types

import Data.List.Extra (unescapeHTML)
import Data.Foldable (fold)
import Control.Monad (foldM)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.List hiding (groupBy)
import Data.Char (isSpace)
import Data.Text (Text)
import Data.Set (Set)
import Data.ByteString.Lazy (ByteString)

import qualified Data.ByteString.Lazy as LB
import qualified Data.Text.Encoding as Text

import qualified Text.HTML.DOM as Html
import qualified Text.XML as Xml
import qualified Data.Text as Text
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Text.PrettyPrint.ANSI.Leijen as P
import qualified Text.PrettyPrint.ANSI.Leijen.Internal as P

-- | An html element
newtype Html = Html Xml.Element

-- | The root of an html page
newtype HtmlPage = HtmlPage Xml.Element

-- | An exported declaration
data Declaration = Declaration
  { dAnchors :: Set Anchor
  , dSignature :: Html
  , dContent :: [Html]
  }

data Module = Module
  { mTitle :: String
  , mDescription :: Maybe Html
  , mDeclarations :: [Declaration]
  , mUrl :: Url
  }

parseHtmlDocument :: ByteString -> HtmlPage
parseHtmlDocument = HtmlPage . Xml.documentRoot . Html.parseLBS

parseHoogleHtml :: String -> Html
parseHoogleHtml
  = Html
  . Xml.documentRoot
  . Html.parseLBS
  . LB.fromStrict
  . Text.encodeUtf8
  . Text.pack
  . (\v -> "<div>" <> v <> "</div>")

parseModuleDocs :: Url -> HtmlPage -> Module
parseModuleDocs url (HtmlPage root) = head $ do
  body    <- findM (is "body" . tag) $ children root
  content <- findM (is "content" . id_) $ children body
  let mtitle = do
        h <- findM (is "module-header" . id_) (children content)
        findM (is "caption" . class_) (children h)
      mdescription = findM (is "description" . id_) (children content)
  interface <- findM (is "interface" . id_) (children content)
  return Module
    { mTitle = Text.unpack $ maybe "" innerText mtitle
    , mDescription = Html <$> mdescription
    , mDeclarations = mapMaybe (parseDeclaration . Html) $ children interface
    , mUrl = url
    }

parseDeclaration :: Html -> Maybe Declaration
parseDeclaration (Html el) = do
  decl <- findM (is "top" . class_) [el]
  ([sig], content) <- return
    $ partition (is "src" . class_) $ children decl

  return Declaration
    { dAnchors = Set.fromList $ anchors el
    , dSignature = Html $ asTag "div" sig
    , dContent = Html <$> content
    }
  where
    asTag t e = e
      { Xml.elementName =
          (Xml.elementName e) { Xml.nameLocalName = t }
      }

findM :: (MonadFail m, Foldable t) => (a -> Bool) -> t a -> m a
findM f x = do
  Just a <- return $ find f x
  return a

is :: Eq a => a -> a -> Bool
is = (==)

children :: Xml.Element -> [Xml.Element]
children element =
  [ n | Xml.NodeElement n <- Xml.elementNodes element ]

tag :: Xml.Element -> Text
tag = Xml.nameLocalName . Xml.elementName

id_ :: Xml.Element -> Text
id_ = attr "id"

class_ :: Xml.Element -> Text
class_ = attr "class"

attr :: Text -> Xml.Element -> Text
attr name =
  fromMaybe ""
  . Map.lookup (Xml.Name name Nothing Nothing)
  . Xml.elementAttributes

innerText :: Xml.Element -> Text
innerText el = flip foldMap (Xml.elementNodes el) $ \case
  Xml.NodeElement e -> innerText e
  Xml.NodeInstruction _ -> mempty
  Xml.NodeContent txt -> txt
  Xml.NodeComment _ -> mempty

anchors :: Xml.Element -> [Anchor]
anchors el = f $ foldMap anchors (children el)
  where
    f = if isAnchor el then (id_ el :) else id

    isAnchor e =
      class_ e == "def" &&
      (Text.isPrefixOf "t:" (id_ e) || Text.isPrefixOf "v:" (id_ e))

sourceLinks :: ModuleLink -> HtmlPage -> [(Anchor, SourceLink)]
sourceLinks (ModuleLink modLink _) (HtmlPage root) = do
  body        <- filter (is "body" . tag) $ children root
  content     <- filter (is "content" . id_) $ children body
  interface   <- filter (is "interface" . id_) $ children content
  declaration <- filter (is "top" . class_) $ children interface

  signature  <- findM (is "src" . class_) $ children declaration
  url <- map (toSourceUrl . attr "href")
    . findM (is "Source" . innerText)
    $ children signature
  srcAnchor <- takeAnchor url
  let surl = SourceLink (dropAnchor url) srcAnchor

  let constructors = filter (is "subs constructors" . class_) $ children declaration
  anchor <- foldMap anchors (signature : constructors)
  return (anchor, surl)
  where
    parent = reverse . tail . dropWhile (/= '/') . reverse

    toSourceUrl relativeUrl = parent modLink <> "/" <> Text.unpack relativeUrl


-- ================================
-- Displaying Haddock's Html
-- ================================

class IsHtml a where
  toElement :: a -> Xml.Element

instance IsHtml Html where
  toElement (Html e) = e

instance IsHtml HtmlPage where
  toElement (HtmlPage p) = p

-- | Render Haddock's Html
prettyHtml :: IsHtml html => html -> P.Doc
prettyHtml = fromMaybe mempty . unXMLElement . toElement
  where
    unXMLElement e = style e . fold =<< unXMLChildren e
    unXMLChildren e =
      case mapMaybe unXMLNode (Xml.elementNodes e) of
        [] -> Nothing
        xs -> Just xs
    unXMLNode = \case
      Xml.NodeInstruction _ -> Nothing
      Xml.NodeContent txt | Text.null txt -> Nothing
      Xml.NodeContent txt -> Just
        $ docwords id
        $ unescapeHTML
        $ Text.unpack txt
      Xml.NodeComment _ -> Nothing
      Xml.NodeElement e -> unXMLElement e

    docwords f [] = P.fillCat (f [])
    docwords f (x:xs)
      | isSpace x = docwords (f . (P.space :)) $ dropWhile isSpace xs
    docwords f xs = docwords (f . (P.text w :)) ys
      where (w, ys) = break isSpace xs

    style e m = classStyle e m  >>= tagStyle e

    classStyle e = case class_ e of
      ""                  -> Just
      -- layout
      "doc"               -> Just . P.nest 2
      "subs methods"      -> Just . P.nest 2
      "subs instances"    -> Just . P.nest 2
      "subs constructors" -> Just . P.nest 2
      -- a declaration wrapper
      "top"               -> const
                              $ Just . mappend P.hardline . P.vsep
                              $ mapMaybe unXMLElement (children e)
      -- style
      "caption"           -> Just . P.bold
      "name"              -> Just . P.dullgreen
      "def"               -> Just . P.bold
      "fixity"            -> Just . italics . P.black
      -- invisible
      "link"              -> hide
      "selflink"          -> hide
      -- modify
      "module-header"     -> const $ unXMLElement =<< findM (is "caption" . class_) (children e)
      _                   -> Just

    tagStyle e = case tag e of
       "h1"      -> Just . linebreak . mappend (P.text "# ")
       "h2"      -> Just . linebreak . mappend (P.text "## ")
       "h3"      -> Just . linebreak . mappend (P.text "### ")
       "h4"      -> Just . linebreak . mappend (P.text "#### ")
       "h5"      -> Just . linebreak . mappend (P.text "##### ")
       "h6"      -> Just . linebreak . mappend (P.text "###### ")
       "tt"      -> Just . P.green
       "pre"     -> const
                      $ Just . P.nest 2 . P.black . linebreak . P.string . Text.unpack
                      $ innerText e
       "code"    -> Just . P.black
       "a"       -> Just . P.cyan
       "b"       -> Just . P.bold
       "p"       -> Just . linebreak
       "dt"      -> Just . P.bold . linebreak
       "dd"      -> Just . linebreak
       "summary" -> Just . linebreak
       "ol"      -> const $ Just . linebreak . P.vsep . numbered $ mapMaybe unXMLElement (children e)
       "ul"      -> const $ Just . linebreak . P.vsep . map bullet $ mapMaybe unXMLElement (children e)
       "td"      | isInstanceDetails e -> hide
                 | otherwise -> Just
       "table"   -> const
                      $ Just .  flip mappend P.hardline . P.vsep . map bullet
                      $ mapMaybe unXMLElement (children e)
       -- don't show instance details
       _         -> Just

    isInstanceDetails e = tag e == "td" && attr "colspan" e == "2"
    linebreak doc = P.hardline <> doc <> P.hardline
    italics = P.Italicize True
    hide = const Nothing

-- | Convert an html page into a src file and inform of line
-- number of SourceLink
fileInfo :: SourceLink -> HtmlPage -> FileInfo
fileInfo (SourceLink _ anchor) (HtmlPage root) = head $ do
  head_ <- filter (is "head" . tag) $ children root
  title <- filter (is "title" . tag) $ children head_
  let filename = Text.unpack $ Text.replace "/" "." $ innerText title <> ".hs"
  body <- filter (is "body" . tag) $ children root
  return $ FileInfo filename (anchorLine anchor body) (innerText body)

-- | File line where the tag is
anchorLine :: Anchor -> Xml.Element -> Maybe Int
anchorLine anchor
  = either Just (const Nothing)
  . anchorNodes 0
  . Xml.elementNodes
  where
    anchorNodes :: Int -> [Xml.Node] -> Either Int Int
    anchorNodes n = foldM anchorNode n

    anchorNode :: Int -> Xml.Node -> Either Int Int -- anchor line or total lines
    anchorNode n = \case
      Xml.NodeInstruction _ -> Right n
      Xml.NodeContent txt -> Right $ n + Text.count "\n" txt
      Xml.NodeComment _ -> Right n
      Xml.NodeElement e ->
        if attr "name" e == anchor
          then Left n
          else anchorNodes n (Xml.elementNodes e)


-- =================================
-- Pretty priting
-- =================================

numbered :: [P.Doc] -> [P.Doc]
numbered = zipWith f [1..]
  where
    f n s = P.fill 2 (P.blue $ P.int n) P.<+> P.align s

bullet :: P.Doc -> P.Doc
bullet doc = P.fill 2 (P.char '-') <> P.align doc

