package local_assets

/**
 * A bundled image.
 *
 * ![pixel](images/pixel.gif)
 */
public func bundled(): Unit {}

/**
 * A missing image must not abort documentation generation.
 *
 * ![missing](images/missing.png)
 */
public func missing(): Unit {}

/**
 * A signature-only pseudo-image must be omitted.
 *
 * ![invalid](images/invalid.gif)
 */
public func invalidContainer(): Unit {}
