package reexport_root

public import reexport_dep.Widget
public import reexport_dep.make as create
public import reexport_dep.{overload, renamed as aliasName}
public import reexport_dep.*
public import reexport_dep.empty.*
public import reexport_dep.empty as emptyPackage
public import reexport_dep.alias_target as ambiguousTarget
public import reexport_dep.conflict.*
public import acme::reexport_dep.make as orgCreate

public let collision = 7
