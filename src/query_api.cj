package cjdoc

import cjdoc.model as query_model
import cjdoc.query.{
    DocumentationQueryException, QueryExecution, loadDocumentationQueryModels,
    loadDocumentationQuerySources, parseDocumentationQueryRequest, queryEncodeResponse, queryExitCode}
import cjdoc.render as query_render
import cjdoc.schema_data as query_schema
import yjson.*

/**
 * One frozen, read-only documentation query session over already loaded
 * snapshots.
 *
 * The session owns the published request contract end to end: it parses and
 * validates the request, maps every rejection and renderer limit onto the machine
 * result envelope, and encodes the one bounded response a client decodes. Loading
 * frozen inputs and dispatching a validated request over them are the captured
 * query core in `cjdoc.query`.
 *
 * Every snapshot, inventory, dependency graph and report is captured before this
 * class exists, so execution never scans source, chooses an SDK, downloads a
 * dependency, compiles a consumer or reaches the network. The same request and
 * the same frozen inputs therefore always produce the same bytes.
 */
public class DocumentationQuerySession {
    private let execution: QueryExecution

    /** Load explicit frozen snapshots through the bounded caller-supplied loader. */
    public init(snapshotPaths: Array<String>) {
        execution = QueryExecution(loadDocumentationQuerySources(snapshotPaths))
    }

    /** Query one captured documentation model without touching the file system. */
    public init(documentation: query_model.DocumentationSet) {
        execution = QueryExecution(loadDocumentationQueryModels([documentation]))
    }

    /** Query several captured documentation models as one explicit catalog. */
    public init(documents: Array<query_model.DocumentationSet>) {
        execution = QueryExecution(loadDocumentationQueryModels(documents))
    }

    /**
     * Execute one strict `cjdoc.query-request/3` request and return exactly one
     * `cjdoc.query-result/4` object.
     *
     * Domain outcomes (ambiguity, scoped absence, incomplete source) are ordinary
     * results; a malformed request is reported through the same envelope so a
     * machine client never parses a human error string.
     */
    public func execute(request: String): String {
        var parsed: ?JsonObject = None
        try {
            parsed = Some(parseDocumentationQueryRequest(request))
        } catch (error: DocumentationQueryException) {
            return execution.failure(JsonNode.object(), error.status, error.code, error.message)
        } catch (_: Exception) {
            return execution.failure(JsonNode.object(), "invalid_request", "request_json",
                "Query request is not one valid JSON object.")
        }
        let value = parsed.getOrThrow()
        try {
            return queryEncodeResponse(execution.dispatch(value))
        } catch (error: DocumentationQueryException) {
            return execution.failure(value, error.status, error.code, error.message)
        } catch (_: query_render.RenderResourceLimitException) {
            return execution.failure(value, "resource_limit", "render_resource_limit",
                "The selected documentation exceeds a documented renderer resource limit.")
        } catch (_: IllegalArgumentException) {
            // A rejected language, audience or scope value is an invalid request,
            // never an internal failure.
            return execution.failure(value, "invalid_request", "request_value",
                "A request value is not supported by the loaded documentation.")
        }
    }

    /**
     * Stable catalog identity of the frozen inputs, equal to the `scope.catalogId`
     * every result reports. It names captured content, not a host path, and is
     * never a publication or release credential.
     */
    public prop catalogIdentity: String {
        get() { execution.catalogIdentity }
    }
}

/** Stable MCP input schema for one operation, derived from the same declaration. */
public func documentationQueryToolSchema(operation: String): String {
    query_schema.documentationQueryOperationSchema(operation)
}

/** A self-contained strict response schema, including the current Doc IR definitions. */
public func documentationQueryOutputSchema(): String {
    query_schema.documentationQueryResultSchema()
}

/**
 * Exit status for a machine query; ambiguity and scoped absence are normal outcomes.
 *
 * The result is decoded with the shared bounded result reader, so a legitimate
 * result above any adapter's default buffer still yields its status instead of
 * being reparsed with a smaller implicit limit.
 */
public func documentationQueryExitCode(result: String): Int64 {
    queryExitCode(result)
}
