package firrtl
import firrtl.annotations.{ModuleTarget,SingleTargetAnnotation}

// Chisel 6 does not expose this CIRCT-supported SV attribute annotation.
case class AttributeAnnotation(target: ModuleTarget, description: String)
  extends SingleTargetAnnotation[ModuleTarget] {
  override def duplicate(n: ModuleTarget): AttributeAnnotation = copy(target=n)
}
