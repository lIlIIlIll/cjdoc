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
