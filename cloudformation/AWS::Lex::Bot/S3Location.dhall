{ Type =
    { S3Bucket : (./../../Fn.dhall).CfnText
    , S3ObjectKey : (./../../Fn.dhall).CfnText
    , S3ObjectVersion : Optional (./../../Fn.dhall).CfnText
    }
, default.S3ObjectVersion = None (./../../Fn.dhall).CfnText
}