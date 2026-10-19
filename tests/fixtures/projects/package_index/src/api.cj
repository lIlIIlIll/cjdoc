/**
 * A single-category package: the index page must render one declarations
 * section whose heading is the category itself.
 */
package package_index

/**
 * Marker type used by the package index acceptance matrix.
 */
public class OnlyEntry {
    /**
     * Returns the entry identifier.
     *
     * @return the identifier
     */
    public func identifier(): String {
        return "package_index"
    }
}
