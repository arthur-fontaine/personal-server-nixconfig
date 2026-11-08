import Foundation
import SwiftParser
import SwiftSyntax

/// What a file is, which decides the rules it's held to (design-rules 9.1–9.4).
public enum FileKind: String, Sendable, CaseIterable {
    /// An app screen: composes HermesUI, never styles itself.
    case screen
    /// A HermesUI component in the content layer.
    case ui
    /// A HermesUI component in the functional layer (`HermesUI/Sources/Chrome`): glass allowed.
    case chrome
    /// HermesUI's token file: the only place with layout numbers.
    case tokens
}

public struct Finding: Hashable, Sendable, CustomStringConvertible {
    public let rule: Rule
    public let file: String
    public let line: Int
    public let column: Int
    public let detail: String

    public var description: String { "\(file):\(line):\(column): error: [design \(rule.rawValue)] \(detail)" }
}

public enum Rule: String, Sendable, CaseIterable {
    /// A screen calls a styling modifier (9.1).
    case styling = "styling-in-screen"
    /// A layout number outside the token file (2.3).
    case layoutLiteral = "layout-literal"
    /// A raw colour in a screen (4.1).
    case rawColor = "raw-color"
    /// A fixed font size or a custom font (3.1).
    case rawFont = "raw-font"
    /// A screen draws a shape (5.2: surfaces come from HermesUI).
    case shape = "shape-in-screen"
    /// A stroke, border or shadow anywhere (5.2, 5.5).
    case stroke = "stroke-or-shadow"
    /// Liquid Glass outside the functional layer (5.5).
    case glass = "glass-in-content"
    /// A HermesUI public API taking or exposing a number or a colour (9.2).
    case publicAPI = "untyped-public-api"
}

public enum DesignCheck {
    /// Modifiers a screen may not call: styling is HermesUI's job.
    static let stylingModifiers: Set<String> = [
        "padding", "font", "fontWeight", "fontDesign", "fontWidth", "bold", "italic", "foregroundStyle",
        "foregroundColor", "background", "backgroundStyle", "clipShape", "cornerRadius", "mask",
        "buttonStyle", "buttonBorderShape", "controlSize", "tint", "lineSpacing", "kerning", "tracking",
        "listRowBackground", "listRowInsets", "scenePadding", "contentMargins", "safeAreaPadding",
        "containerShape", "glassEffect", "opacity", "blur", "brightness", "saturation", "colorMultiply",
        "shadow", "stroke", "strokeBorder", "border", "textCase", "dynamicTypeSize", "allowsTightening",
    ]
    /// Arguments that are layout numbers wherever they appear.
    static let layoutLabels: Set<String> = [
        "spacing", "horizontalSpacing", "verticalSpacing", "width", "height", "minWidth", "maxWidth",
        "minHeight", "maxHeight", "idealWidth", "idealHeight", "cornerRadius", "radius", "minLength",
        "lineWidth", "min", "ideal", "max",
    ]
    /// Calls whose every argument — labelled, unlabelled or a trailing closure — is layout.
    static let layoutCalls: Set<String> = [
        "padding", "frame", "offset", "position", "scaleEffect", "lineSpacing", "kerning", "tracking",
        "contentMargins", "safeAreaPadding", "inset", "cornerRadius", "aspectRatio",
        "containerRelativeFrame", "rotationEffect", "transformEffect", "rotation3DEffect", "projectionEffect",
    ]
    static let shapes: Set<String> = [
        "RoundedRectangle", "Circle", "Capsule", "Rectangle", "Ellipse", "ConcentricRectangle",
        "UnevenRoundedRectangle", "ContainerRelativeShape",
    ]
    static let untypedAPITypes: Set<String> = [
        "CGFloat", "Color", "UIColor", "Font", "ShapeStyle", "AnyShapeStyle", "EdgeInsets", "CGSize", "CGPoint",
        "Double", "Float", "Int", "CGRect",
    ]

    public static func check(source: String, file: String, kind: FileKind) -> [Finding] {
        let tree = Parser.parse(source: source)
        let visitor = Visitor(file: file, kind: kind, converter: SourceLocationConverter(fileName: file, tree: tree))
        visitor.walk(tree)
        return visitor.findings.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }
}

final class Visitor: SyntaxVisitor {
    let file: String
    let kind: FileKind
    let converter: SourceLocationConverter
    var findings: [Finding] = []
    /// Depth of `public extension` blocks: their members are public.
    private var publicExtensionDepth = 0

    init(file: String, kind: FileKind, converter: SourceLocationConverter) {
        self.file = file
        self.kind = kind
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func add(_ rule: Rule, _ node: some SyntaxProtocol, _ detail: String) {
        let loc = node.startLocation(converter: converter)
        let f = Finding(rule: rule, file: file, line: loc.line, column: loc.column, detail: detail)
        if !findings.contains(f) { findings.append(f) }
    }

    private var isHermesUI: Bool { kind != .screen }

    // MARK: Calls

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let name = calledName(node)
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text {
            if ["stroke", "strokeBorder", "border", "shadow"].contains(member) {
                add(.stroke, node, "`.\(member)` — no outlines or shadows: surfaces separate by fill (design-rules 5.2, 5.5)")
            } else if kind == .screen, DesignCheck.stylingModifiers.contains(member) {
                add(.styling, node, "`.\(member)(…)` in a screen — compose a HermesUI component or modifier instead (design-rules 9.1)")
            }
            if member == "glassEffect", kind != .chrome {
                add(.glass, node, "`.glassEffect` outside HermesUI/Chrome — Liquid Glass is for the functional layer (HIG Materials, design-rules 5.5)")
            }
            if member == "minimumScaleFactor" {
                add(.rawFont, node, "`.minimumScaleFactor` shrinks text below its Dynamic Type size — let it wrap (design-rules 3.4)")
            }
            // `.environment(\.font, …)`: a font set without `.font`.
            if member == "environment", kind == .screen,
               let first = node.arguments.first?.expression.trimmedDescription, first.hasPrefix("\\."),
               ["font", "dynamicTypeSize", "legibilityWeight"].contains(where: { first.dropFirst(2).hasPrefix($0) }) {
                add(.styling, node, "`.environment(\(first), …)` in a screen styles text — use a TextRole (design-rules 9.1)")
            }
            if member == "system", node.arguments.contains(where: { $0.label?.text == "size" }) {
                add(.rawFont, node, "`.system(size:)` — Dynamic Type text styles only (design-rules 3.1)")
            }
            if member == "custom", node.calledExpression.as(MemberAccessExprSyntax.self)?.base?.trimmedDescription ?? "Font" == "Font" {
                add(.rawFont, node, "custom font — SF Pro only (design-rules 3.1)")
            }
        }
        if name == "GlassEffectContainer", kind != .chrome {
            add(.glass, node, "`GlassEffectContainer` outside HermesUI/Chrome (design-rules 5.5)")
        }
        if kind == .screen, let name, ["Color", "UIColor"].contains(name) {
            add(.rawColor, node, "`\(name)(…)` in a screen — semantic tones and surfaces only (design-rules 4.1)")
        }
        if kind != .tokens {
            checkLayoutLiterals(node, name: name)
        }
        return .visitChildren
    }

    private func calledName(_ node: FunctionCallExprSyntax) -> String? {
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        return nil
    }

    private func checkLayoutLiterals(_ node: FunctionCallExprSyntax, name: String?) {
        let layoutCall = name.map(DesignCheck.layoutCalls.contains) ?? false
        var exprs: [Syntax] = []
        for arg in node.arguments {
            let isLayout = layoutCall || (arg.label.map { DesignCheck.layoutLabels.contains($0.text) } ?? false)
            if isLayout { exprs.append(Syntax(arg.expression)) }
        }
        // `containerRelativeFrame(.horizontal) { w, _ in w * 0.5 }`: the closure computes layout.
        if layoutCall {
            if let c = node.trailingClosure { exprs.append(Syntax(c)) }
            for c in node.additionalTrailingClosures { exprs.append(Syntax(c.closure)) }
        }
        for e in exprs {
            if let literal = nonZeroLiteral(in: e) {
                add(.layoutLiteral, literal, "layout number `\(literal.trimmedDescription)` — use a token (Spacing, PetSize, a component) (design-rules 2.3)")
            }
        }
    }

    /// A numeric literal other than 0 inside an argument (0 is no distance, not a magic number).
    private func nonZeroLiteral(in expr: some SyntaxProtocol) -> Syntax? {
        for token in expr.tokens(viewMode: .sourceAccurate) {
            switch token.tokenKind {
            case .integerLiteral(let t), .floatLiteral(let t):
                if Double(t.replacingOccurrences(of: "_", with: "")) != 0 { return Syntax(token) }
            default: continue
            }
        }
        return nil
    }

    // MARK: References

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if kind == .screen, DesignCheck.shapes.contains(name) {
            add(.shape, node, "`\(name)` in a screen — surfaces and shapes come from HermesUI (design-rules 5.2, 9.3)")
        }
        if kind == .screen, name == "Color", node.parent?.is(MemberAccessExprSyntax.self) == true {
            add(.rawColor, node, "`Color.…` in a screen — semantic tones and surfaces only (design-rules 4.1)")
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        // `.buttonStyle(.glass)`, `.glassProminent`: glass button styles.
        if ["glass", "glassProminent"].contains(node.declName.baseName.text), node.base == nil, kind != .chrome {
            add(.glass, node, "`.\(node.declName.baseName.text)` style outside HermesUI/Chrome (design-rules 5.5)")
        }
        return .visitChildren
    }

    // MARK: HermesUI's public API (9.2)

    // `public struct X<S: ShapeStyle>`: a colour parameter at the type level.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if isHermesUI, isPublic(node.modifiers) { checkGenerics(node.genericParameterClause, node.genericWhereClause, in: node.name.text) }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if isHermesUI, isPublic(node.modifiers) { checkGenerics(node.genericParameterClause, node.genericWhereClause, in: node.name.text) }
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if isHermesUI, isPublic(node.modifiers) { checkGenerics(node.genericParameterClause, node.genericWhereClause, in: node.name.text) }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(node.modifiers) { publicExtensionDepth += 1 }
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        if isPublic(node.modifiers) { publicExtensionDepth -= 1 }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if isHermesUI, exposed(node.modifiers) {
            checkParameters(node.signature.parameterClause.parameters, in: node.name.text)
            if let ret = node.signature.returnClause?.type { checkType(ret, in: node.name.text) }
            checkGenerics(node.genericParameterClause, node.genericWhereClause, in: node.name.text)
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if isHermesUI, exposed(node.modifiers) {
            checkParameters(node.signature.parameterClause.parameters, in: "init")
            checkGenerics(node.genericParameterClause, node.genericWhereClause, in: "init")
        }
        return .visitChildren
    }

    /// `init<S: ShapeStyle>(fill: S)`: a colour by another name.
    private func checkGenerics(_ params: GenericParameterClauseSyntax?, _ whereClause: GenericWhereClauseSyntax?, in name: String) {
        for clause in [params.map(Syntax.init), whereClause.map(Syntax.init)].compactMap({ $0 }) {
            for token in clause.tokens(viewMode: .sourceAccurate) where DesignCheck.untypedAPITypes.contains(token.text) {
                add(.publicAPI, clause, "`\(name)` is generic over `\(token.text)` — HermesUI's public API takes tokens, never numbers or colours (design-rules 9.2)")
                return
            }
        }
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if isHermesUI, exposed(node.modifiers) {
            for binding in node.bindings {
                if let type = binding.typeAnnotation?.type { checkType(type, in: binding.pattern.trimmedDescription) }
            }
        }
        return .visitChildren
    }

    private func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { ["public", "open"].contains($0.name.text) }
    }

    private func exposed(_ modifiers: DeclModifierListSyntax) -> Bool {
        if isPublic(modifiers) { return true }
        let restricted = modifiers.contains { ["private", "fileprivate", "internal"].contains($0.name.text) }
        return publicExtensionDepth > 0 && !restricted
    }

    private func checkParameters(_ params: FunctionParameterListSyntax, in name: String) {
        for p in params { checkType(p.type, in: name) }
    }

    private func checkType(_ type: TypeSyntax, in name: String) {
        for token in type.tokens(viewMode: .sourceAccurate) where DesignCheck.untypedAPITypes.contains(token.text) {
            add(.publicAPI, type, "`\(name)` exposes `\(token.text)` — HermesUI's public API takes tokens (Spacing, TextRole, Tone, Surface…), never numbers or colours (design-rules 9.2)")
            return
        }
    }
}

public extension Finding {
    /// Counts a non-source error (a stale legacy entry) without a location of its own.
    static let placeholder = Finding(rule: .styling, file: "", line: 0, column: 0, detail: "")
}
