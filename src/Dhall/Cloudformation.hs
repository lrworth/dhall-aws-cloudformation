{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

module Dhall.Cloudformation where

import           Control.Arrow     (Arrow ((&&&)))
import           Data.Aeson
import           Data.Aeson.Types
import           Data.Foldable     (Foldable (fold))
import qualified Data.HashMap.Lazy as HML (lookup)
import           Data.List         (groupBy)
import           Data.Map          (Map, fromList, keys, singleton, toList)
import           Data.Maybe        (catMaybes)
import           Data.Text         (Text, breakOn, isPrefixOf, pack, replace)
import qualified Data.Text         as T hiding (any)
import           Data.Void
import           Dhall.Core        (Directory (Directory), Expr (App, Assert, Embed, Equivalent, Field, None, Optional, Record, RecordLit, TextLit),
                                    Expr (Record), File (File),
                                    FilePrefix (Here), Import (Import),
                                    ImportHashed (ImportHashed),
                                    ImportMode (Code),
                                    ImportType (Local, Remote), RecordField,
                                    Scheme (HTTPS), URL (URL),
                                    makeFieldSelection, makeRecordField)
import qualified Dhall.Core        as D
import qualified Dhall.Map         as DM
import           Dhall.Src         (Src)
import           GHC.Generics      (Generic)
import           Prelude

type DhallExpr = Expr Src Import
type DhallRecordField = RecordField Src Import

data Properties = Properties
  { required          :: Maybe Bool,
    primitiveType     :: Maybe Text,
    typ               :: Maybe Text,
    itemType          :: Maybe Text,
    primitiveItemType :: Maybe Text,
    doc               :: Maybe Text
  }
  deriving (Generic, Show, Eq)

data ResourceTypes = ResourceTypes
  { rdocument :: Maybe Text,
    props     :: Map Text Properties
  }
  deriving (Generic, Show, Eq)

data PropertyTypes = PropTypes
  { pdocument :: Maybe Text,
    pprops    :: Map Text Properties
  } | PrimitiveTypes Properties
  deriving (Generic, Show, Eq)

-- | https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cfn-resource-specification-format.html
data Spec = Spec
  { resourceTypes                :: Map Text ResourceTypes,
    propertyTypes                :: Map Text PropertyTypes,
    resourceSpecificationVersion :: Text
  }

instance FromJSON Spec where
  parseJSON = withObject "Spec" $ \o ->
    Spec
      <$> o .: "ResourceTypes"
      <*> o .: "PropertyTypes"
      <*> o .: "ResourceSpecificationVersion"

instance FromJSON ResourceTypes where
  parseJSON = withObject "ResrouceTypes" $ \o ->
    ResourceTypes
      <$> o .:? "Documentation"
      <*> o .: "Properties"

instance FromJSON PropertyTypes where
  parseJSON a = withObject "PropertyTypes" (\o -> case HML.lookup "Properties" o of
    Just p -> PropTypes
      <$> o .:? "Documentation"
      <*> o .: "Properties"
    Nothing -> PrimitiveTypes <$> parseJSON a) a

instance FromJSON Properties where
  parseJSON = withObject "Properties" $ \o ->
    Properties
      <$> o .:? "Required"
      <*> o .:? "PrimitiveType"
      <*> o .:? "Type"
      <*> o .:? "ItemType"
      <*> o .:? "PrimitiveItemType"
      <*> o .:? "Documentation"

preludeType t = Embed (
  Import (
      ImportHashed Nothing (
          Remote (URL HTTPS "raw.githubusercontent.com" (File (Directory $ reverse ["dhall-lang", "dhall-lang", "v20.0.0", "Prelude", t]) "Type") Nothing Nothing))
      ) Code)

inBlackList a = any (flip isPrefixOf a)
  [
    "AWS::EMR",
    "AWS::DataBrew::Recipe",
    "AWS::FIS::ExperimentTemplate",
    "AWS::Macie::FindingsFilter",
    "AWS::SageMaker",
    "AWS::S3::StorageLens",
    "AWS::StepFunctions::StateMachine",
    "AWS::MWAA::Environment"
  ]
convertSpec :: Spec -> Map Text DhallExpr
convertSpec (Spec rt pt v) = convertResourceTypes rt
  <> fold (convertPropertyTypes <$> groupPreffix pt)
  <> propsAndResourceIndex
  <> fromList [("SpecificationVersion.dhall", mkText v)]
  <> fromList [("package.dhall", genPackage (keys rt))]
  where
    genPackage l = RecordLit $ DM.fromList $ toField <$> filter (not . inBlackList) l
    toField name = (name, makeRecordField $ mkImportLocalCode [] name)
    groupPreffix :: Map Text PropertyTypes -> [(Text, Map Text PropertyTypes)]
    groupPreffix pt = (\a -> ((preffix . head) a, fromList a)) <$> groupBy (\a b -> preffix a == preffix b) (toList pt)
    propsAndResourceIndex :: Map Text DhallExpr
    propsAndResourceIndex = fromList $ (genIndex (keys pt)) <$> (keys rt)
    genIndex pf key =
      ( key <> ".dhall",
        RecordLit $ DM.fromList $
        ("Properties", makeRecordField $ mkImportLocalCode [key] "Properties")
        :("Resources", makeRecordField $ mkImportLocalCode [key] "Resources")
        : (mkPropRecord <$> filter ((== key) . preffixPropName) pf)
      )
    preffix :: (Text, PropertyTypes) -> Text
    preffix = fst . breakOn "." . fst
    preffixPropName :: Text -> Text
    preffixPropName = fst . breakOn "."
    suffixPropName :: Text -> Text
    suffixPropName = (T.drop 1) . snd . (breakOn ".")
    mkPropRecord name = (suffixPropName name, makeRecordField $ mkImportLocalCode [preffixPropName name] (suffixPropName name))
convertResourceTypes :: Map Text ResourceTypes -> Map Text DhallExpr
convertResourceTypes m = fromList $ do
  (k, v) <- toList m
  let p = convertProps (props v)
  [(k <> "/Resources.dhall", specDhall k v), (k <> "/Properties.dhall", p)]
  where
    specDhall :: Text -> ResourceTypes -> DhallExpr
    specDhall k s = toRecordCompletion (
      [
        ("Properties", Just $ makeRecordField $ mkImportDirLocal [] "Properties"),
        ("Type", Just $ makeRecordField D.Text)
      ],
      [
        ("Type", Just $ makeRecordField (mkText k))
      ]
        )

convertPropertyTypes :: (Text, Map Text PropertyTypes) -> Map Text DhallExpr
convertPropertyTypes (key, m) = propTypes (toList m)
  where
    propTypes lm = fromList $ do
      (k, v) <- lm
      return (replace "." "/" k <> ".dhall", getType v)
    getType (PropTypes  _ v)   = convertProps v
    getType (PrimitiveTypes v) = convertProps (fromList [("Properties", v)])
convertProps :: Map Text Properties -> DhallExpr
convertProps m = (toRecordCompletion . unzip . split) (toList m)
  where
    split :: [(Text, Properties)] -> [((Text, Maybe DhallRecordField), (Text, Maybe DhallRecordField))]
    split = fmap ((fmap toRecordField) &&& (fmap toRecordDefault))

toRecordField :: Properties -> Maybe DhallRecordField

toRecordField (Properties (Just False) _ (Just "Map") (Just itemType) _ doc) = Just $ makeRecordField (App D.Optional (App (App (preludeType "Map") D.Text) $ mkImportLocal itemType))
toRecordField (Properties _ _ (Just "Map") (Just itemType) _ doc) = Just $ makeRecordField (App (App (preludeType "Map") D.Text) $ mkImportLocal itemType)
toRecordField (Properties (Just False) _ (Just "Map") _ (Just primitiveItemType) doc) = Just $
  makeRecordField (App D.Optional (App (App (preludeType "Map") D.Text) (primitiveToDhall primitiveItemType)))
toRecordField (Properties _ _ (Just "Map") _ (Just primitiveItemType) doc) = Just $
  makeRecordField (App (App (preludeType "Map") D.Text) (primitiveToDhall primitiveItemType))
toRecordField (Properties (Just False) _ (Just "List") (Just itemType) _ doc) = Just $ makeRecordField (App D.Optional (App D.List $ mkImportLocal itemType))
toRecordField (Properties _ _ (Just "List") (Just itemType) _ doc) = Just $ makeRecordField (App D.List $ mkImportLocal itemType)
toRecordField (Properties (Just False) _ (Just "List") _ (Just primitiveItemType) doc) = Just $
  makeRecordField (App D.Optional (App D.List (primitiveToDhall primitiveItemType)))
toRecordField (Properties _ _ (Just "List") _ (Just primitiveItemType) doc) = Just $
  makeRecordField (App D.List (primitiveToDhall primitiveItemType))
toRecordField (Properties (Just False) Nothing (Just typ) _ _ doc) = Just $ makeRecordField (App Optional $ mkImportLocal typ)
toRecordField (Properties _ Nothing (Just typ) _ _ doc) = Just $ makeRecordField (mkImportLocal typ)
toRecordField (Properties (Just False) (Just pt) _ _ _ doc) = Just $ makeRecordField (App Optional (primitiveToDhall pt))
toRecordField (Properties _ (Just pt) _ _ _ doc) = Just $ makeRecordField (primitiveToDhall pt)
toRecordField p = Just $ makeRecordField (assertError "cannot decode property" (pack $ show p))

toRecordDefault :: Properties -> Maybe DhallRecordField
toRecordDefault (Properties (Just False) Nothing (Just "List") (Just itemType) _ doc) = Just $ makeRecordField $ App None $ App D.List $ mkImportLocal itemType
toRecordDefault (Properties (Just False) Nothing (Just "List") Nothing (Just primItemType) doc) = Just $ makeRecordField $ App None $ App D.List $ primitiveToDhall primItemType
toRecordDefault (Properties (Just False) Nothing (Just typ) Nothing Nothing doc) = Just $ makeRecordField $ App None $ mkImportLocal typ
toRecordDefault (Properties (Just False) (Just pt) Nothing _ _ doc) = Just $makeRecordField $ App None (primitiveToDhall pt)
toRecordDefault p = Nothing

mkImportLocal :: Text -> DhallExpr
mkImportLocal "Tag" = mkImportDirLocal [".."] "Tag"
mkImportLocal typ   = mkImportDirLocal [] typ

mkImportDirLocal :: [Text] -> Text -> DhallExpr
mkImportDirLocal dir typ = Field
  (mkImportLocalCode dir typ)
  (makeFieldSelection "Type")

mkImportLocalCode dir typ = Embed (Import (ImportHashed Nothing (Local Here (File (Directory dir) (typ <> ".dhall")))) Code)

toRecordCompletion :: ([(Text, Maybe DhallRecordField)], [(Text, Maybe DhallRecordField)]) -> DhallExpr
toRecordCompletion (types, defaults) =
  toRecordLit
    [ ("Type", makeRecordField . toRecord . catMaybes $ flipTupleMaybe <$> types),
      ("default", makeRecordField . toRecordLit . catMaybes $ flipTupleMaybe <$> defaults)
    ]

toRecord :: [(Text, DhallRecordField)] -> DhallExpr
toRecord = Record . DM.fromList
toRecordLit :: [(Text, DhallRecordField)] -> DhallExpr
toRecordLit = RecordLit . DM.fromList

primitiveToDhall :: Text -> DhallExpr
primitiveToDhall "String" = D.Union (DM.fromList [("Text", Just D.Text), ("Fn", Just (preludeType "JSON"))])
primitiveToDhall "Integer" = D.Integer
primitiveToDhall "Double" = D.Double
primitiveToDhall "Boolean" = D.Bool
primitiveToDhall "Json" = preludeType "JSON"
primitiveToDhall "Timestamp" = D.Text
primitiveToDhall "Long" = D.Natural
primitiveToDhall a = assertError "cannot decode Primitive type" a

flipTupleMaybe (a, Just b)  = Just (a, b)
flipTupleMaybe (a, Nothing) = Nothing

assertError :: Text -> Text -> DhallExpr
assertError a b = Assert $ Equivalent (mkText a) (mkText b)

mkText :: Text -> DhallExpr
mkText s = TextLit (D.Chunks [] s)
