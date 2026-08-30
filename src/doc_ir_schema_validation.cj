package cjdoc

import cjdoc.model as public_model
import cjdoc.render as public_render

func decodeValidatedDocIr(text: String): public_model.DocumentationSet {
    public_render.decodeDocIr(text)
}

func validateGeneratedDocIr(documentation: public_model.DocumentationSet): Unit {
    let encoded = public_render.encodeDocIr(documentation)
    let migrated = decodeValidatedDocIr(encoded)
    if (migrated.schemaVersion != public_model.DOC_IR_SCHEMA_VERSION) {
        throw IllegalStateException("generated Doc IR did not validate as v7")
    }
}
