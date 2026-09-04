package cjdoc.model


protected func validateRasterAsset(mediaType: String, bytes: Array<Byte>): Int64 {
    if (bytes.isEmpty() || bytes.size > DOC_IR_MAX_ASSET_BYTES) {
        throw IllegalArgumentException("raster asset byte size is outside the supported limit")
    }
    if (mediaType != "image/png" && mediaType != "image/jpeg" &&
        mediaType != "image/gif" && mediaType != "image/webp" &&
        mediaType != "image/avif") {
        throw IllegalArgumentException("raster asset media type is unsupported")
    }
    let dimensions = match (rasterDimensions(mediaType, bytes)) {
        case Some(found) => found
        case None => throw IllegalArgumentException(
            "raster asset container, payload, or dimensions are invalid")
    }
    if (dimensions.width <= 0 || dimensions.height <= 0 ||
        dimensions.width > DOC_IR_MAX_ASSET_DIMENSION ||
        dimensions.height > DOC_IR_MAX_ASSET_DIMENSION ||
        dimensions.width > DOC_IR_MAX_ASSET_PIXELS / dimensions.height) {
        throw IllegalArgumentException("raster asset dimensions or pixel count exceed the limit")
    }
    dimensions.width * dimensions.height
}
