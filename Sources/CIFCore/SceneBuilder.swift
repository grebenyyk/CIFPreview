import AppKit
import SceneKit
import CIFCore
import SymmetryKit

/// Builds the styled SceneKit scene: light ball-and-stick with CPK colors,
/// gray bonds, thin dark cell edges, soft three-point lighting on a
/// white→light-gray gradient. Deliberately contrasted with iRASPA's
/// low-quality dark single-light preview.
public enum SceneBuilder {

    // ---- visual spec ----
    public static let canvasSize = CGSize(width: 1600, height: 1200)
    static let fieldOfView: CGFloat = 40
    static let frameMargin = 1.10          // camera distance = r / sin(fov/2) × margin
    static let elevation = 22.0 * Double.pi / 180
    static let azimuth = 30.0 * Double.pi / 180
    static let ballScale = 0.32            // display radius = 0.32 × covalent radius
    static let ballRadiusClamp = (0.12, 1.2)
    static let bondColor = NSColor(red: 0xA8 / 255, green: 0xAC / 255, blue: 0xB2 / 255, alpha: 1)
    static let bondRadius = 0.09
    static let cellColor = NSColor(red: 0x3A / 255, green: 0x3F / 255, blue: 0x45 / 255, alpha: 1)
    static let cellRadius = 0.015

    public static func scene(for model: RenderModel) -> SCNScene? {
        guard !model.atoms.isEmpty else { return nil }
        let scene = SCNScene()
        scene.background.contents = gradientImage()
        scene.lightingEnvironment.contents = NSColor.white  // neutral ambient base

        // ---- atoms --------------------------------------------------------
        let radii = CovalentRadii.shared
        let lodSegments = model.atoms.count <= 3000 ? 32 : (model.atoms.count <= 12_000 ? 20 : 12)
        var displayRadius: [String: CGFloat] = [:]
        var geometries: [String: SCNGeometry] = [:]
        var materials: [String: SCNMaterial] = [:]

        let atomsRoot = SCNNode()
        for atom in model.atoms {
            let element = atom.element
            let geom: SCNGeometry
            if let cached = geometries[element] {
                geom = cached
            } else {
                let cov = radii[element]
                let r = min(max(CGFloat(cov) * ballScale, ballRadiusClamp.0), ballRadiusClamp.1)
                displayRadius[element] = r
                let sphere = SCNSphere(radius: r)
                sphere.segmentCount = lodSegments
                let material = SCNMaterial()
                material.lightingModel = .blinn
                material.diffuse.contents = cpkColor(element)
                material.ambient.contents = cpkColor(element)
                material.ambient.intensity = 0.32
                material.specular.contents = NSColor(white: 0.25, alpha: 1)
                material.shininess = 0.35
                material.isDoubleSided = false
                sphere.materials = [material]
                geometries[element] = sphere
                materials[element] = material
                geom = sphere
            }
            let node = SCNNode(geometry: geom)
            node.simdPosition = SIMD3<Float>(atom.position)
            atomsRoot.addChildNode(node)
        }
        scene.rootNode.addChildNode(atomsRoot)

        // ---- bonds --------------------------------------------------------
        var imageAtoms: [(String, SIMD3<Double>)] = []
        let segments = bondSegments(model: model, imageAtoms: &imageAtoms)
        if !segments.isEmpty {
            let bondNode = SCNNode(geometry: mergedCylinders(segments: segments,
                                                             radius: bondRadius,
                                                             color: bondColor))
            scene.rootNode.addChildNode(bondNode)
        }

        // ---- unit cell ----------------------------------------------------
        if let cell = model.cell {
            let corners = cellCorners(cell)
            let edges = [(0, 1), (1, 3), (3, 2), (2, 0),
                         (4, 5), (5, 7), (7, 6), (6, 4),
                         (0, 4), (1, 5), (2, 6), (3, 7)]
            let cellSegments = edges.map { (from: corners[$0.0], to: corners[$0.1]) }
            let cellNode = SCNNode(geometry: mergedCylinders(segments: cellSegments,
                                                             radius: cellRadius,
                                                             color: cellColor))
            scene.rootNode.addChildNode(cellNode)
        }

        // ---- ghost atoms at cell faces (image positions the in-cell bonds reach)
        for (element, position) in imageAtoms {
            let node = SCNNode(geometry: geometries[element])
            node.simdPosition = SIMD3<Float>(position)
            atomsRoot.addChildNode(node)
        }

        // ---- framing & lights ---------------------------------------------
        let (center, radius) = boundingSphere(model: model, radii: displayRadius,
                                              imageAtoms: imageAtoms)
        let cameraNode = cameraFraming(center: center, radius: radius)
        scene.rootNode.addChildNode(cameraNode)
        addLights(to: scene, center: center, radius: radius)
        return scene
    }

    // MARK: - framing

    private static func boundingSphere(model: RenderModel, radii: [String: CGFloat],
                                       imageAtoms: [(String, SIMD3<Double>)]) -> (SIMD3<Double>, Double) {
        var minP = model.atoms[0].position, maxP = minP
        for a in model.atoms {
            minP = simd_min(minP, a.position)
            maxP = simd_max(maxP, a.position)
        }
        if let cell = model.cell {
            for c in cellCorners(cell) {
                minP = simd_min(minP, c)
                maxP = simd_max(maxP, c)
            }
        }
        let center = (minP + maxP) / 2
        var radius = 0.0
        for a in model.atoms {
            radius = max(radius, simd_distance(a.position, center) + Double(radii[a.element] ?? 0.3))
        }
        // image atoms at cell faces extend past the in-cell content
        for (_, position) in imageAtoms {
            radius = max(radius, simd_distance(position, center))
        }
        return (center, max(radius, 1.0))
    }

    private static func cameraFraming(center: SIMD3<Double>, radius: Double) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = fieldOfView
        camera.zNear = 0.01
        camera.zFar = radius * 100 + 1000
        let distance = Double(radius / sin(Double(fieldOfView) / 2 * .pi / 180)) * frameMargin
        let direction = SIMD3<Double>(cos(elevation) * sin(azimuth),
                                      sin(elevation),
                                      cos(elevation) * cos(azimuth))
        let node = SCNNode()
        node.name = "camera"
        node.camera = camera
        node.simdPosition = SIMD3<Float>(center + direction * distance)
        node.look(at: SCNVector3(center.x, center.y, center.z),
                  up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        return node
    }

    private static func addLights(to scene: SCNScene, center: SIMD3<Double>, radius: Double) {
        let d = radius * 10

        let key = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 900
        key.light = keyLight
        key.simdPosition = SIMD3<Float>(center + SIMD3<Double>(-0.6, 0.8, 1.0) * d)
        key.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 300
        fill.light = fillLight
        fill.simdPosition = SIMD3<Float>(center + SIMD3<Double>(0.8, -0.2, 0.5) * d)
        fill.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(fill)

        let ambient = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 350
        ambientLight.color = NSColor(white: 1.0, alpha: 1)
        ambient.light = ambientLight
        scene.rootNode.addChildNode(ambient)
    }

    // MARK: - geometry helpers

    private typealias Segment = (from: SIMD3<Double>, to: SIMD3<Double>)

    /// bond segments with half-bond treatment of periodic crossings:
    /// a bond to a lattice image is drawn as two halves meeting at the boundary
    /// bond segments with half-bond treatment of periodic crossings; bonds to a
    /// lattice image also report the image atom position, which the caller renders
    /// so the bond lands on a sphere instead of dangling past the cell face
    private static func bondSegments(model: RenderModel,
                                     imageAtoms: inout [(String, SIMD3<Double>)]) -> [Segment] {
        var segments: [Segment] = []
        segments.reserveCapacity(model.bonds.count * 2)
        guard let lattice = model.cell?.columnsAsMatrix else {
            for b in model.bonds {
                segments.append((model.atoms[b.i].position, model.atoms[b.j].position))
            }
            return segments
        }
        let offsets: [SIMD3<Double>] = [lattice.columns.0, lattice.columns.1, lattice.columns.2]
        var seenImages: Set<UInt64> = []
        for b in model.bonds {
            let p1 = model.atoms[b.i].position
            let p2Image = model.atoms[b.j].position
                + offsets[0] * Double(b.offset.x)
                + offsets[1] * Double(b.offset.y)
                + offsets[2] * Double(b.offset.z)
            if b.offset == SIMD3<Int32>.zero {
                segments.append((p1, p2Image))
            } else {
                let mid = (p1 + p2Image) / 2
                segments.append((p1, mid))
                segments.append((p2Image, mid))
                let key = UInt64(truncatingIfNeeded: b.j) &* 1_000_003
                    &+ UInt64(bitPattern: Int64(b.offset.x)) &* 7
                    &+ UInt64(bitPattern: Int64(b.offset.y)) &* 131
                    &+ UInt64(bitPattern: Int64(b.offset.z)) &* 7919
                if seenImages.insert(key).inserted {
                    imageAtoms.append((model.atoms[b.j].element, p2Image))
                }
            }
        }
        return segments
    }

    private static func cellCorners(_ cell: RenderCell) -> [SIMD3<Double>] {
        let (a, b, c) = (cell.a, cell.b, cell.c)
        return [SIMD3<Double>.zero, a, b, a + b, c, a + c, b + c, a + b + c]
    }

    /// one merged SCNGeometry for all segments (single draw call): an 8-sided
    /// open cylinder per segment, vertex positions baked in Cartesian space
    private static func mergedCylinders(segments: [Segment], radius: Double, color: NSColor) -> SCNGeometry {
        let sides = 8
        var positions: [SCNVector3] = []
        var indices: [Int32] = []
        positions.reserveCapacity(segments.count * sides * 2)
        indices.reserveCapacity(segments.count * sides * 6)

        var normals: [SCNVector3] = []
        normals.reserveCapacity(positions.capacity)
        for s in segments {
            let axis = s.to - s.from
            let length = simd_length(axis)
            guard length > 1e-9 else { continue }
            let dir = axis / length
            // build an orthogonal basis (dir, u, v)
            let helper = abs(dir.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            let u = simd_normalize(simd_cross(dir, helper))
            let v = simd_cross(dir, u)

            let base = Int32(positions.count)
            for ring in 0..<2 {
                let center = ring == 0 ? s.from : s.to
                for k in 0..<sides {
                    let angle = Double(k) / Double(sides) * 2 * .pi
                    let radial = u * cos(angle) + v * sin(angle)
                    positions.append(SCNVector3(center + radial * radius))
                    normals.append(SCNVector3(radial))
                }
            }
            for k in 0..<sides {
                let k2 = Int32((k + 1) % sides)
                let a0 = base + Int32(k), a1 = base + k2
                let b0 = base + Int32(sides) + Int32(k), b1 = base + Int32(sides) + k2
                indices += [a0, b0, a1, a1, b0, b1]
            }
        }

        let source = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source, normalSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = color
        material.ambient.contents = color
        material.ambient.intensity = 0.32
        material.specular.contents = NSColor(white: 0.2, alpha: 1)
        material.shininess = 0.2
        material.isDoubleSided = false
        geometry.materials = [material]
        return geometry
    }

    // MARK: - colors & background

    /// CPK (jMol convention) colors, reused from the vendored SKColorSet table
    private static func cpkColor(_ element: String) -> NSColor {
        guard let rgb = SKColorSet.jMol[element] else {
            return NSColor(red: 0.54, green: 0.54, blue: 0.54, alpha: 1)
        }
        return NSColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                       green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255,
                       alpha: 1)
    }

    /// white → #EEEFF3 vertical gradient with ±1 LSB dither noise, so the
    /// near-white ramp doesn't band on the large preview canvas.
    /// Built through a CGContext so SceneKit gets a well-formed sRGB texture.
    private static func gradientImage() -> NSImage {
        let w = 4, h = 512
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = makeGradientCGImage(context: context, width: w, height: h)
        else {
            let fallback = NSImage(size: NSSize(width: 1, height: 1))
            fallback.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
            fallback.unlockFocus()
            return fallback
        }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    private static func makeGradientCGImage(context: CGContext, width: Int, height: Int) -> CGImage? {
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func noise() -> Double {   // xorshift → [-0.5, 0.5)
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed >> 11) / Double(1 << 53) - 0.5
        }
        let top = (Double(255), Double(255), Double(255))
        let bottom = (Double(0xEE), Double(0xEF), Double(0xF3))
        for y in 0..<height {
            let t = Double(y) / Double(height - 1)
            let rgb = [top.0 + (bottom.0 - top.0) * t,
                       top.1 + (bottom.1 - top.1) * t,
                       top.2 + (bottom.2 - top.2) * t]
            for x in 0..<width {
                let o = (y * width + x) * 4
                for c in 0..<3 {
                    buffer[o + c] = UInt8(max(0, min(255, rgb[c] + noise().rounded())))
                }
            }
        }
        guard let data = context.data else { return nil }
        data.copyMemory(from: &buffer, byteCount: buffer.count)
        return context.makeImage()
    }
}
