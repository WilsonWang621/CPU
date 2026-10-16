package firrtl
import firrtl.annotations.{Target, SingleTargetAnnotation}

// CIRCT's supported annotation for ordinary SystemVerilog module attributes.
case class AttributeAnnotation(target: Target, description: String)
    extends SingleTargetAnnotation[Target] {
  override def duplicate(n: Target): AttributeAnnotation = copy(target = n)
}
