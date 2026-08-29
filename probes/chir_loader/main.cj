import std.fs.*
import stdx.chir.*

main(args: Array<String>): Int64 {
    if (args.size != 1) {
        println("usage: chir_loader <package.chir>")
        return 2
    }
    let bytes = File.readFrom(args[0])
    let pkg = unsafe {
        let raw = acquireArrayRawData(bytes)
        let value = deserializePackage(CPointer<UInt8>(raw.pointer), bytes.size)
        releaseArrayRawData(raw)
        value
    }
    println("package=${pkg.name}")
    println("functions=${pkg.functions.size}")
    println("classes=${pkg.classDefs.size}")
    println("structs=${pkg.structDefs.size}")
    println("enums=${pkg.enumDefs.size}")
    println("extends=${pkg.extendDefs.size}")
    for (function in pkg.functions where function.packageName == pkg.name) {
        let owner = match (function.declaredParent) {
            case Some(value) => value.srcCodeName
            case None => "<package>"
        }
        println("function=${function.srcCodeName}|public=${function.isPublic()}|owner=${owner}|generic=${function.genericTypeParams.size}|params=${function.parameters.size}|type=${function.funcSrcCodeType}")
    }
    for (definition in pkg.classDefs) {
        println("class-like=${definition.srcCodeName}|public=${definition.isPublic()}|generic=${definition.genericTypeParams.size}|interfaces=${definition.implementedInterfaceTypes.size}|methods=${definition.methods.size}|members=${definition.instanceVars.size}")
        for (member in definition.instanceVars) {
            println("member=${member.name}|type=${member.ty.qualifiedName}|location=${member.location}")
        }
    }
    for (definition in pkg.structDefs) {
        println("struct=${definition.srcCodeName}|public=${definition.isPublic()}|generic=${definition.genericTypeParams.size}|members=${definition.instanceVars.size}")
    }
    for (definition in pkg.enumDefs) {
        println("enum=${definition.srcCodeName}|public=${definition.isPublic()}|generic=${definition.genericTypeParams.size}")
    }
    for (definition in pkg.extendDefs) {
        println("extend=${definition.extendedType.qualifiedName}|methods=${definition.methods.size}")
    }
    return 0
}
