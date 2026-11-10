// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original artwork drawn in code: handheld-style shells with bevels, screen glass, speaker
// grilles, LEDs, screws and surface textures. TwinPlay branding only: no third-party logos,
// trademarks or wording.
import SwiftUI

enum ShellStyle: Equatable { case plain, ds, lite, gba, clamshell, brick, color, phone, twin, nes, snes }

struct RealisticShell: View {
    let style: ShellStyle
    let palette: SkinPalette
    let lid: LidStyle
    let layout: DualScreenLayout
    let size: CGSize
    /// Skin id, for per-model touches (stripes, circuitry, finish).
    var variant: String = ""

    private var p: SkinPalette { palette }
    /// #22 Heritage pack: extra hardware details (see HeritageSkins.swift).
    private var heritage: Bool { variant.hasPrefix("heritage") }
    /// Heritage DS shells with a matte (grained) finish: the original wide model and the camera model.
    private var matteDS: Bool { variant.hasPrefix("heritagePhat") || variant.hasPrefix("heritageCam") }
    private var phatDS: Bool { variant.hasPrefix("heritagePhat") }
    private var camDS: Bool { variant.hasPrefix("heritageCam") }
    /// Clamshells in brushed metal (the rest are glossy lacquer).
    private var brushed: Bool { !["realGBASPRed", "heritageFlipCobalt", "heritageFlipFlame"].contains(variant) }
    private var screens: [CGRect] { layout.isSingle ? [layout.top] : [layout.top, layout.bottom] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if layout.outer { outerShell }
            else if style == .twin && layout.twin { refTwinShell }
            else {
                if lid.translucent {
                    ClearInsides(size: CGSize(width: size.width - 8, height: size.height - 8), bar: nil).clipShape(shellShape)
                        .position(x: size.width / 2, y: size.height / 2)
                }
                shellBody
                details
            }
        }
        .frame(width: size.width, height: size.height)
        .drawingGroup()               // static artwork: rasterised once, cheap to composite
        .allowsHitTesting(false)
    }

    // MARK: shell

    private var shellShape: CornerRect {
        let w = size.width - 8, h = size.height - 8
        switch style {
        case .brick: return CornerRect(tl: 14, tr: 14, bl: 16, br: min(w, h) * 0.2)   // one large lower-right corner
        case .gba where w > h: return CornerRect(all: h * 0.32)                     // rounded grip ends
        case .nes: return CornerRect(all: min(w, h) * 0.06)                         // console bezel, nearly square corners
        case .snes: return CornerRect(all: min(28, min(w, h) * 0.08))
        case .color: return CornerRect(tl: 18, tr: 18, bl: min(w, h) * 0.12, br: min(w, h) * 0.12)
        default: return CornerRect(all: 30)
        }
    }

    private var shellBody: some View {
        let w = size.width - 8, h = size.height - 8
        let shape = shellShape
        return ZStack {
            shape.fill(LinearGradient(colors: [p.shellTop, p.shellBottom], startPoint: .top, endPoint: .bottom))
            // Material: brushed metal (clamshell), fine matte grain (the rest).
            if style == .clamshell && brushed { BrushedMetal().clipShape(shape).opacity(0.5) }
            else if (style != .lite && style != .twin) || matteDS { Grain(density: style == .brick ? 0.9 : 0.6).clipShape(shape).opacity(style == .ds ? 0.35 : 0.6) }
            // Lite: high-gloss lacquer, a diagonal specular sweep.
            if style == .lite || (style == .twin && !matteDS) || (style == .clamshell && !brushed) {
                shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.18), .init(color: .white.opacity(style == .twin ? 0.18 : 0.32), location: 0.30),
                                                  .init(color: .white.opacity(0), location: 0.44)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .blendMode(.screen)
            }
            // Soft top light and a darker lower edge: the shell reads as a moulded volume.
            shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.10 + 0.25 * lid.gloss), location: 0),
                                              .init(color: .white.opacity(0), location: 0.35),
                                              .init(color: .black.opacity(0), location: 0.75),
                                              .init(color: .black.opacity(0.14), location: 1)],
                                      startPoint: .top, endPoint: .bottom))
            if style == .gba && w > h { gripVolumes(w: w, h: h).clipShape(shape) }
            // Bevel: bright upper-left rim, dark lower-right rim, and a parting line just inside.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.65), lid.edge.opacity(0.95)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3)
            shape.inset(by: 7).strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
            shape.inset(by: 8).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .position(x: size.width / 2, y: size.height / 2)
    }

    /// The rounded hand grips at both ends of a wide shell.
    private func gripVolumes(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            ForEach([0.0, 1.0], id: \.self) { side in
                Ellipse()
                    .fill(RadialGradient(colors: [.white.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: h * 0.42))
                    .frame(width: h * 0.75, height: h * 0.9)
                    .position(x: side == 0 ? h * 0.30 : w - h * 0.30, y: h * 0.55)
            }
        }
        .frame(width: w, height: h)
    }

    // MARK: details per style

    @ViewBuilder private var details: some View {
        switch style {
        case .ds: dsDetails
        case .lite: liteDetails
        case .twin: refDetails
        case .phone: phoneDetails
        case .gba: gbaDetails
        case .clamshell: clamshellDetails
        case .brick: brickDetails
        case .color: colorDetails
        case .nes: nesDetails
        case .snes: snesDetails
        case .plain: EmptyView()
        }
    }

    // DS: hinge cylinder with end caps, screws, speaker grilles beside the top screen, mic hole,
    // power/charge LEDs, glass bezels.
    @ViewBuilder private var dsDetails: some View {
        let top = layout.top, bot = layout.isSingle ? layout.top : layout.bottom
        if !layout.isSingle { hingeBar(between: top, bot) }
        bezel(top, radius: 10, margin: 11)
        screws([CGPoint(x: 22, y: size.height - 22), CGPoint(x: size.width - 22, y: size.height - 22)])
        // Small moulded squares at the upper screen's corners (original DS face detail).
        if !layout.isSideBySide && top.minX > 30 {
            let corners = [CGPoint(x: top.minX - 18, y: top.minY + 8), CGPoint(x: top.maxX + 18, y: top.minY + 8),
                           CGPoint(x: top.minX - 18, y: top.maxY - 8), CGPoint(x: top.maxX + 18, y: top.maxY - 8)]
            ForEach(0..<4, id: \.self) { i in let pt = corners[i]
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.black.opacity(0.25), lineWidth: 0.6))
                    .frame(width: 6, height: 6).position(pt)
            }
        }
        if !layout.isSingle { bezel(bot, radius: 8, margin: 9, touch: true) }
        // Speaker grilles left and right of the upper screen when there is room.
        if !layout.isSideBySide && top.minX > 46 {
            dotGrille(rows: 5, cols: 3, pitch: 6, dot: 2.6).position(x: top.minX / 2, y: top.midY)
            dotGrille(rows: 5, cols: 3, pitch: 6, dot: 2.6).position(x: (top.maxX + size.width) / 2, y: top.midY)
        }
        if !layout.isSingle {
            let hy = (top.maxY + bot.minY) / 2
            if !layout.isSideBySide {
                Circle().fill(Color.black.opacity(0.55)).frame(width: 3.5, height: 3.5).position(x: top.midX, y: hy)   // microphone
                ledPair(x: min(top.maxX + 26, size.width - 26), y: hy)
            }
        }
        wordmark("TwinPlay", size: 11, sub: nil)
            .position(x: top.midX, y: min(top.maxY + 4.5, size.height))
            .opacity(layout.isSideBySide ? 0 : 0.9)
    }

    // Lite: slim glossy shell, thin hinge with a centre seam, tiny speaker slots flanking the
    // upper screen, a small power LED; no screws on the face.
    @ViewBuilder private var liteDetails: some View {
        let top = layout.top, bot = layout.isSingle ? layout.top : layout.bottom
        if !layout.isSingle && !layout.isSideBySide {
            let hy = (top.maxY + bot.minY) / 2
            Rectangle().fill(LinearGradient(colors: [Color.black.opacity(0.22), Color.white.opacity(0.25), Color.black.opacity(0.18)],
                                            startPoint: .top, endPoint: .bottom))
                .frame(width: size.width - 20, height: 6).position(x: size.width / 2, y: hy)
            Circle().fill(Color.black.opacity(0.5)).frame(width: 3, height: 3).position(x: top.midX, y: hy + 7)
        } else if !layout.isSingle { hingeBar(between: top, bot) }
        bezel(top, radius: 8, margin: 7)
        if !layout.isSingle { bezel(bot, radius: 6, margin: 7, touch: true) }
        if !layout.isSideBySide && top.minX > 30 {
            ForEach([top.minX / 2, (top.maxX + size.width) / 2], id: \.self) { x in
                VStack(spacing: 4) { ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 2.5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.black.opacity(0.55)).frame(width: 2.4, height: 2.4) } }
                } }
                .position(x: x, y: top.minY + 16)
            }
        }
        led(color: Color(red: 0.35, green: 1, blue: 0.45), label: nil)
            .position(x: min(top.maxX + 14, size.width - 14), y: max(top.minY - 10, 14))
        wordmark("TwinPlay lite", size: 9, sub: nil)
            .position(x: top.midX, y: max(top.minY - 9, 10)).opacity(0.7)
    }

    // Phone-style slab: flat face, deep screen bezel, a row of speaker dots between the
    // shoulders, a charge LED; the pocket-gray one adds the twin stripes and slanted grille.
    @ViewBuilder private var phoneDetails: some View {
        let r = layout.top
        let pocket = variant == "phoneDMG"
        bezel(r, radius: 14, margin: 8, lower: pocket ? 18 : 8)
        if pocket {
            VStack(spacing: 2.5) {
                Rectangle().fill(Color(red: 0.55, green: 0.12, blue: 0.32)).frame(height: 1.6)
                Rectangle().fill(Color(red: 0.16, green: 0.20, blue: 0.48)).frame(height: 1.6)
            }
            .frame(width: r.width - 30).position(x: r.midX, y: r.minY - 2)
            slantedGrille().position(x: size.width - 56, y: size.height - 46)
            Text("TwinPlay").font(.system(size: 13, weight: .heavy)).italic()
                .foregroundStyle(Color(red: 0.17, green: 0.20, blue: 0.47)).position(x: r.minX + 40, y: r.maxY + 26)
        } else {
            HStack(spacing: 7) { ForEach(0..<6, id: \.self) { _ in Circle().fill(Color.black.opacity(0.45)).frame(width: 3.2, height: 3.2) } }
                .position(x: size.width / 2, y: r.maxY + 30)
            dotGrille(rows: 3, cols: 3, pitch: 6, dot: 2.4, round: true).position(x: 34, y: r.maxY + 70)
            dotGrille(rows: 3, cols: 3, pitch: 6, dot: 2.4, round: true).position(x: size.width - 34, y: r.maxY + 70)
            led(color: Color(red: 0.3, green: 0.7, blue: 1), label: nil).position(x: size.width - 26, y: size.height - 26)
        }
        if variant == "phoneIndigo" {
            // Indigo clear: faint circuitry visible through the shell.
            Path { path in
                for i in 0..<9 {
                    let y = r.maxY + 60 + CGFloat(i) * 34
                    path.move(to: CGPoint(x: 24, y: y)); path.addLine(to: CGPoint(x: size.width * 0.4, y: y))
                    path.addLine(to: CGPoint(x: size.width * 0.4 + 18, y: y + 18)); path.addLine(to: CGPoint(x: size.width - 24, y: y + 18))
                }
            }
            .stroke(Color.white.opacity(0.10), lineWidth: 1.2)
        }
        wordmark("TwinPlay", size: 9, sub: nil).position(x: r.midX, y: r.maxY + 12).opacity(pocket ? 0 : 0.6)
    }

    // NES-style console face: a deep rectangular bezel, a red power lamp and a short vent.
    // No product name and no logo. The on-screen pad carries B and A.
    @ViewBuilder private var nesDetails: some View {
        let r = layout.top
        bezel(r, radius: 4, margin: 14, lower: 18)
        wordmark("TwinPlay", size: 11, sub: nil).position(x: r.midX, y: min(r.maxY + 12, size.height - 16))
        led(color: Color(red: 0.85, green: 0.12, blue: 0.14), label: "POWER")
            .position(x: max(r.minX - 8, 36), y: r.minY + 8)
        let ventX = min(r.maxX + 28, size.width - 22)
        VStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { _ in
                Capsule().fill(Color.black.opacity(0.45)).frame(width: 16, height: 2)
            }
        }
        .position(x: ventX, y: r.midY)
    }

    // Super NES-style face: softer corners, shoulder recesses at the top, a power lamp.
    // The coloured diamond is the touch controls, not artwork on the shell.
    @ViewBuilder private var snesDetails: some View {
        let r = layout.top
        let wide = size.width > size.height
        bezel(r, radius: 8, margin: 12, lower: 16)
        wordmark("TwinPlay", size: 11, sub: nil).position(x: r.midX, y: min(r.maxY + 11, size.height - 16))
        led(color: Color(red: 0.25, green: 0.85, blue: 0.45), label: nil)
            .position(x: min(r.maxX + 16, size.width - 20), y: max(r.minY - 6, 18))
        // Shoulder recesses: two shallow wells along the top edge. They are not the L/R buttons.
        let wellW = min(wide ? 90 : 70, size.width * 0.22)
        ForEach([0.0, 1.0], id: \.self) { side in
            Capsule()
                .fill(Color.black.opacity(0.18))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                .frame(width: wellW, height: 10)
                .position(x: side == 0 ? 18 + wellW / 2 : size.width - 18 - wellW / 2, y: 16)
        }
    }

    // Wide single-screen handheld: grip ends, shoulder bumps, LED, dotted speaker, screws.
    @ViewBuilder private var gbaDetails: some View {
        let r = layout.top
        let wide = size.width > size.height
        shoulderBumps(wide: wide)
        bezel(r, radius: wide ? 12 : 10, margin: 12, lower: 16)
        wordmark("TwinPlay", size: 12, sub: nil).position(x: r.midX, y: r.maxY + 9)
        led(color: Color(red: 0.35, green: 1, blue: 0.45), label: "POWER")
            .position(x: r.minX + 22, y: r.maxY + 9)
        speakerDiagonal().position(x: wide ? min(r.maxX + 46, size.width - 50) : r.maxX - 34,
                                   y: wide ? r.maxY - 6 : min(r.maxY + 44, size.height - 30))
        screws([CGPoint(x: 26, y: size.height - 26), CGPoint(x: size.width - 26, y: size.height - 26)])
        if heritage {
            // Wide handheld: a moulded ridge framing the face, the link port and headphone notches on the edge.
            CornerRect(all: wide ? size.height * 0.28 : 24).inset(by: 14)
                .stroke(LinearGradient(colors: [.white.opacity(0.22), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
                .frame(width: size.width - 8, height: size.height - 8).position(x: size.width / 2, y: size.height / 2)
            edgeNotch(x: size.width / 2, y: 6, w: 34)
            edgeNotch(x: size.width * 0.3, y: size.height - 6, w: 16)
        }
    }

    // Clamshell: brushed metal, screen half and controller half joined by a hinge barrel.
    @ViewBuilder private var clamshellDetails: some View {
        let r = layout.top
        let portrait = size.height >= size.width
        bezel(r, radius: 9, margin: 10, lower: 12)
        wordmark("TwinPlay", size: 10, sub: "SP").position(x: r.midX, y: r.maxY + 7)
        led(color: Color(red: 0.35, green: 0.85, blue: 1), label: nil).position(x: r.maxX + 2, y: r.minY - 12)
        if portrait {
            let y = min(r.maxY + 30, layout.controlsArea.minY + 30)
            barrel(rect: CGRect(x: 18, y: y - 9, width: size.width - 36, height: 18))
            screws([CGPoint(x: 30, y: y), CGPoint(x: size.width - 30, y: y)])
            Rectangle().fill(Color.black.opacity(0.16)).frame(width: size.width - 16, height: 1).position(x: size.width / 2, y: y + 12)
            if heritage {
                // Front-light button in the middle of the controller half, below the hinge.
                lightButton().position(x: size.width / 2, y: y + 30)
                Text("POWER").font(.system(size: 5.5, weight: .bold)).foregroundStyle(engraveColor.opacity(0.55))
                    .position(x: r.maxX + 2, y: r.minY - 4)
            }
        } else {
            barrel(rect: CGRect(x: 20, y: size.height - 30, width: size.width - 40, height: 14))
        }
    }

    // Brick: slate bezel with two thin coloured lines, battery LED, italic wordmark, slanted grille.
    @ViewBuilder private var brickDetails: some View {
        let r = layout.top
        let pad: CGFloat = max(16, r.width * 0.07)
        let bz = CGRect(x: r.minX - pad * 1.4, y: r.minY - pad * 1.1, width: r.width + pad * 2.8, height: r.height + pad * 2.0)
        // Top edge: engraved power strip.
        Text("◂ OFF · ON ▸").font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.32)).position(x: 64, y: 20)
        Rectangle().fill(Color.black.opacity(0.14)).frame(width: size.width - 40, height: 1).position(x: size.width / 2, y: 30)
        CornerRect(tl: 8, tr: 8, bl: 8, br: bz.width * 0.13)
            .fill(LinearGradient(colors: [p.bezel.opacity(0.95), p.bezel], startPoint: .top, endPoint: .bottom))
            .overlay(CornerRect(tl: 8, tr: 8, bl: 8, br: bz.width * 0.13)
                .strokeBorder(Color.black.opacity(0.3), lineWidth: 1))
            .frame(width: bz.width, height: bz.height).position(x: bz.midX, y: bz.midY)
        // The two thin lines across the top of the bezel.
        VStack(spacing: 2.5) {
            Rectangle().fill(Color(red: 0.55, green: 0.12, blue: 0.32)).frame(height: 1.6)
            Rectangle().fill(Color(red: 0.16, green: 0.20, blue: 0.48)).frame(height: 1.6)
        }
        .frame(width: bz.width - 26).position(x: bz.midX, y: bz.minY + pad * 0.55)
        Text(heritage ? "DOT MATRIX WITH STEREO SOUND" : "DOT MATRIX · TwinPlay").font(.system(size: heritage ? 6.5 : 7, weight: .bold, design: heritage ? .default : .rounded)).tracking(0.6).italic(heritage)
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.horizontal, 4).background(p.bezel).position(x: bz.midX, y: bz.minY + pad * 0.55)
        if heritage {
            // Unlit liquid-crystal glass around the picture: the pale olive of the original screen.
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(red: 0.60, green: 0.64, blue: 0.44), Color(red: 0.52, green: 0.57, blue: 0.38)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                .frame(width: r.width + pad * 0.9, height: r.height + pad * 0.9).position(x: r.midX, y: r.midY)
        }
        glass(r, radius: 2)
        led(color: Color(red: 1, green: 0.18, blue: 0.15), label: "BATTERY").position(x: bz.minX + pad * 0.7, y: r.midY - r.height * 0.2)
        // Italic wordmark under the bezel.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("TwinPlay").font(.system(size: 17, weight: .heavy, design: .default)).italic()
            Text("Pocket").font(.system(size: 13, weight: .semibold, design: .serif)).italic()
        }
        .foregroundStyle(Color(red: 0.17, green: 0.20, blue: 0.47))
        .position(x: max(bz.minX, 12) + 58, y: min(bz.maxY + 16, size.height - 16))
        slantedGrille().position(x: size.width - 56, y: size.height - 46)
        if heritage {
            // Bottom edge: headphone jack marking and the ribbed contrast wheel on the left side.
            Text("Ω PHONES").font(.system(size: 6.5, weight: .bold, design: .rounded)).foregroundStyle(Color.black.opacity(0.32))
                .position(x: size.width / 2, y: size.height - 14)
            VStack(spacing: 2) { ForEach(0..<7, id: \.self) { _ in Rectangle().fill(Color.black.opacity(0.22)).frame(width: 4, height: 1.2) } }
                .position(x: 8, y: max(bz.midY, 60))
        }
    }

    // Colour pocket: glossy black bezel, multicolour wordmark, round speaker, LED.
    @ViewBuilder private var colorDetails: some View {
        let r = layout.top
        let pad: CGFloat = max(14, r.width * 0.06)
        let bz = CGRect(x: r.minX - pad * 1.3, y: r.minY - pad, width: r.width + pad * 2.6, height: r.height + pad * 2.2)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.16), p.bezel], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .frame(width: bz.width, height: bz.height).position(x: bz.midX, y: bz.midY)
        glass(r, radius: 3)
        HStack(spacing: 1) {
            ForEach(Array("TwinPlay".enumerated()), id: \.offset) { i, ch in
                Text(String(ch)).foregroundStyle([Color(red: 1, green: 0.30, blue: 0.30), Color(red: 1, green: 0.80, blue: 0.20),
                                                  Color(red: 0.35, green: 0.85, blue: 0.40), Color(red: 0.35, green: 0.60, blue: 1)][i % 4])   // cycles: the wordmark is longer than 4 letters
            }
            Text(" COLOR").foregroundStyle(Color.white.opacity(0.8))
        }
        .font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(0.8)
        .position(x: bz.midX, y: bz.maxY - pad * 0.5)
        led(color: heritage ? Color(red: 1, green: 0.25, blue: 0.2) : Color(red: 0.4, green: 1, blue: 0.4), label: heritage ? "POWER" : nil)
            .position(x: bz.minX + pad * 0.6, y: r.minY + 14)
        if heritage {
            // Infrared window on the top edge and the slanted speaker slots of the colour model.
            RoundedRectangle(cornerRadius: 2).fill(LinearGradient(colors: [Color(red: 0.35, green: 0.04, blue: 0.08), Color(red: 0.15, green: 0.02, blue: 0.04)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.6))
                .frame(width: 30, height: 7).position(x: size.width - 50, y: 9)
            edgeNotch(x: 60, y: 6, w: 26)
        }
        if heritage {
            dotGrille(rows: 2, cols: 3, pitch: 8, dot: 3.6, round: true).rotationEffect(.degrees(-30)).position(x: size.width - 48, y: size.height - 44)
        } else {
            dotGrille(rows: 3, cols: 3, pitch: 7, dot: 3.4, round: true).position(x: size.width - 48, y: size.height - 44)
        }
        screws([CGPoint(x: 22, y: size.height - 22)])
    }

    // MARK: parts

    /// Screen surround with a moulded lip, an inner shadow and the glass highlight.
    @ViewBuilder private func bezel(_ r: CGRect, radius: CGFloat, margin m: CGFloat, lower: CGFloat? = nil, touch: Bool = false) -> some View {
        let lowerM = lower ?? m
        let frame = CGRect(x: r.minX - m, y: r.minY - m, width: r.width + m * 2, height: r.height + m + lowerM)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [p.bezel.opacity(0.9), p.bezel], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.black.opacity(0.45), .white.opacity(0.25)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
            .shadow(color: .white.opacity(0.25), radius: 0, x: 0, y: 1)
            .frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
        glass(r, radius: 2, touch: touch)
    }

    /// Dark rim right around the picture, plus a faint diagonal reflection.
    private func glass(_ r: CGRect, radius: CGFloat, touch: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(Color.black.opacity(0.8), lineWidth: 2)
            .background(RoundedRectangle(cornerRadius: radius).fill(Color.black))
            .overlay(LinearGradient(stops: [.init(color: .white.opacity(touch ? 0.05 : 0.08), location: 0),
                                            .init(color: .white.opacity(0), location: 0.4)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: r.width + 4, height: r.height + 4).position(x: r.midX, y: r.midY)
    }

    @ViewBuilder private func hingeBar(between a: CGRect, _ b: CGRect) -> some View {
        if layout.isSideBySide {
            let x = (a.maxX + b.minX) / 2, h = max(a.height, b.height) + 40
            barrel(rect: CGRect(x: x - 8, y: a.midY - h / 2, width: 16, height: h), vertical: true)
        } else {
            let y = (a.maxY + b.minY) / 2, w = min(max(a.width, b.width) + 60, size.width - 24)
            barrel(rect: CGRect(x: a.midX - w / 2, y: y - 8, width: w, height: 16))
            screws([CGPoint(x: a.midX - w / 2 + 12, y: y), CGPoint(x: a.midX + w / 2 - 12, y: y)])
        }
    }

    /// A cylindrical hinge barrel: light core, dark edges, segment joints near the ends.
    private func barrel(rect r: CGRect, vertical: Bool = false) -> some View {
        let shade = LinearGradient(colors: [lid.hinge.opacity(0.75), lid.light, lid.hinge, lid.edge],
                                   startPoint: vertical ? .leading : .top, endPoint: vertical ? .trailing : .bottom)
        return ZStack {
            Capsule().fill(shade)
            Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.8)
            if vertical {
                VStack { Rectangle().frame(height: 1); Spacer(); Rectangle().frame(height: 1) }.padding(.vertical, r.height * 0.18)
                    .foregroundStyle(Color.black.opacity(0.22))
            } else {
                HStack { Rectangle().frame(width: 1); Spacer(); Rectangle().frame(width: 1) }.padding(.horizontal, r.width * 0.18)
                    .foregroundStyle(Color.black.opacity(0.22))
            }
        }
        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
    }

    private func screws(_ points: [CGPoint]) -> some View {
        ForEach(Array(points.enumerated()), id: \.offset) { _, pt in
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.45)], center: .topLeading, startRadius: 0, endRadius: 6))
                Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.6)
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: 5, height: 1)
                Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1, height: 5)
            }
            .frame(width: 7, height: 7)
            .shadow(color: .white.opacity(0.4), radius: 0, x: 0.5, y: 0.5)
            .position(pt)
        }
    }

    private func led(color: Color, label: String?) -> some View {
        VStack(spacing: 2) {
            Circle().fill(RadialGradient(colors: [.white, color, color.opacity(0.6)], center: .center, startRadius: 0, endRadius: 3.5))
                .frame(width: 6, height: 6).shadow(color: color.opacity(0.9), radius: 3)
            if let label { Text(label).font(.system(size: 5.5, weight: .bold)).foregroundStyle(engraveColor.opacity(0.8)) }
        }
    }

    private func ledPair(x: CGFloat, y: CGFloat) -> some View {
        HStack(spacing: 6) {
            led(color: Color(red: 0.35, green: 0.85, blue: 1), label: nil)
            led(color: Color(red: 1, green: 0.55, blue: 0.15), label: nil).opacity(0.5)
        }
        .position(x: x, y: y)
    }

    private var engraveColor: Color { luminance(p.shellTop) < 0.4 ? .white : .black }

    /// Debossed wordmark: dark text with a light lower edge.
    private func wordmark(_ text: String, size s: CGFloat, sub: String?) -> some View {
        HStack(spacing: 3) {
            Text(text).font(.system(size: s, weight: .black, design: .rounded)).tracking(s * 0.18)
            if let sub { Text(sub).font(.system(size: s * 0.8, weight: .bold, design: .rounded)) }
        }
        .foregroundStyle(engraveColor.opacity(0.42))
        .shadow(color: (luminance(p.shellTop) < 0.4 ? Color.black : Color.white).opacity(0.5), radius: 0, x: 0, y: 0.8)
    }

    private func dotGrille(rows: Int, cols: Int, pitch: CGFloat, dot: CGFloat, round: Bool = false) -> some View {
        VStack(spacing: pitch - dot) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: pitch - dot) {
                    ForEach(0..<cols, id: \.self) { _ in
                        Circle().fill(Color.black.opacity(0.55))
                            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5).offset(y: 0.5))
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
        .padding(round ? 5 : 0)
        .background(round ? AnyView(Circle().fill(Color.black.opacity(0.10))) : AnyView(Color.clear))
    }

    /// Six slanted slots (lower-right speaker of a pocket brick).
    private func slantedGrille() -> some View {
        HStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { _ in
                Capsule().fill(LinearGradient(colors: [Color.black.opacity(0.5), Color.black.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.6).offset(x: 0.6, y: 0.8))
                    .frame(width: 5, height: 46)
            }
        }
        .rotationEffect(.degrees(-28))
    }

    /// Dotted speaker in a diagonal block (lower right of the wide handheld).
    private func speakerDiagonal() -> some View {
        VStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<(row + 2), id: \.self) { _ in Circle().fill(Color.black.opacity(0.5)).frame(width: 3, height: 3) }
                }
            }
        }
    }

    @ViewBuilder private func shoulderBumps(wide: Bool) -> some View {
        let w: CGFloat = min(size.width * 0.28, 140)
        ForEach([0.0, 1.0], id: \.self) { side in
            CornerRect(tl: side == 0 ? 26 : 6, tr: side == 0 ? 6 : 26, bl: 0, br: 0)
                .fill(LinearGradient(colors: [lid.dark.opacity(0.75), lid.dark.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                .frame(width: w, height: 10)
                .position(x: side == 0 ? 8 + w / 2 : size.width - 8 - w / 2, y: 9)
        }
    }

    /// Port / notch cut into the shell edge (link port, headphone jack).
    private func edgeNotch(x: CGFloat, y: CGFloat, w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.25), lineWidth: 0.6).offset(y: 0.6))
            .frame(width: w, height: 4).position(x: x, y: y)
    }

    /// Small round front-light button with a sun glyph (Heritage flip shells).
    private func lightButton() -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.3)).frame(width: 17, height: 17).blur(radius: 0.6)
            Circle().fill(LinearGradient(colors: [p.buttonFill.opacity(0.9), p.buttonFill], startPoint: .top, endPoint: .bottom)).frame(width: 14, height: 14)
            Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 0.8).frame(width: 14, height: 14)
            Image(systemName: "sun.max.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(p.buttonText.opacity(0.8))
        }
    }

    private func luminance(_ c: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return Double(0.299 * r + 0.587 * g + 0.114 * b)
    }
}

/// Fine deterministic speckle (moulded plastic texture).
private struct Grain: View {
    var density: Double
    var body: some View {
        Canvas { ctx, sz in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
            let n = Int(Double(sz.width * sz.height) / 90 * density)
            for i in 0..<n {
                let x = rnd() * sz.width, y = rnd() * sz.height
                ctx.fill(Path(CGRect(x: x, y: y, width: 0.8, height: 0.8)),
                         with: .color(i % 2 == 0 ? Color.black.opacity(0.10) : Color.white.opacity(0.12)))
            }
        }
    }
}

/// Horizontal brushed-metal streaks.
private struct BrushedMetal: View {
    var body: some View {
        Canvas { ctx, sz in
            var seed: UInt64 = 0x2545F4914F6CDD1D
            func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
            var y: CGFloat = 0
            while y < sz.height {
                let a = 0.04 + rnd() * 0.10
                ctx.fill(Path(CGRect(x: 0, y: y, width: sz.width, height: 0.6)),
                         with: .color(rnd() > 0.5 ? Color.white.opacity(a) : Color.black.opacity(a * 0.6)))
                y += 0.8 + rnd() * 1.6
            }
        }
    }
}

/// Rounded rectangle with its own radius per corner (iOS 16 has no UnevenRoundedRectangle).
struct CornerRect: InsettableShape {
    var tl: CGFloat, tr: CGFloat, bl: CGFloat, br: CGFloat
    var inset: CGFloat = 0
    init(tl: CGFloat, tr: CGFloat, bl: CGFloat, br: CGFloat) { self.tl = tl; self.tr = tr; self.bl = bl; self.br = br }
    init(all r: CGFloat) { self.init(tl: r, tr: r, bl: r, br: r) }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let m = min(r.width, r.height) / 2
        func c(_ v: CGFloat) -> CGFloat { max(min(v - inset, m), 0) }
        let a = c(tl), b = c(tr), d = c(br), e = c(bl)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + a, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - b, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - b, y: r.minY + b), radius: b, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - d))
        p.addArc(center: CGPoint(x: r.maxX - d, y: r.maxY - d), radius: d, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + e, y: r.maxY - e), radius: e, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + a))
        p.addArc(center: CGPoint(x: r.minX + a, y: r.minY + a), radius: a, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> CornerRect { var s = self; s.inset += amount; return s }

}

extension RealisticShell {
    // MARK: closed iPhone Duo, landscape outer display

    /// Full-bleed classic handheld face: body edge to edge with rounded corners, a black screen
    /// bezel with a subtle TwinPlay wordmark and a dotted speaker grille (the MENU pill is the
    /// game view's movable button; the decorative dot under R was removed). The touch layer draws
    /// the D-pad, A/B, SELECT/START and (GBA) L/R.
    @ViewBuilder private var outerShell: some View {
        let r = layout.outerCornerRadius
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        let sp = layout.outerSpots
        let bz = layout.outerBezel
        let darkBody = luminance(p.shellTop) < 0.45
        let clear = lid.translucent
        ZStack(alignment: .topLeading) {
            // Moulded body: diagonal gradient, darker rim, soft specular sheen, faint grain.
            shape.fill(Color.black.opacity(clear ? 0.55 : 0))          // see-through: dark insides behind tinted plastic
            if clear {
                // Faint inner detail seen through the plastic: board outline, screw posts, traces.
                RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1)
                    .frame(width: size.width * 0.7, height: size.height * 0.62).position(x: size.width / 2, y: size.height * 0.48)
                ForEach([CGPoint(x: 0.12, y: 0.16), CGPoint(x: 0.88, y: 0.16), CGPoint(x: 0.12, y: 0.86), CGPoint(x: 0.88, y: 0.86)], id: \.x.hashValue) { pt in
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: 1.2).frame(width: 10, height: 10)
                        .position(x: size.width * pt.x, y: size.height * pt.y)
                }
                Path { q in
                    q.move(to: CGPoint(x: size.width * 0.2, y: size.height * 0.92)); q.addLine(to: CGPoint(x: size.width * 0.35, y: size.height * 0.82))
                    q.move(to: CGPoint(x: size.width * 0.8, y: size.height * 0.08)); q.addLine(to: CGPoint(x: size.width * 0.66, y: size.height * 0.16))
                }.stroke(Color.white.opacity(0.08), lineWidth: 2)
            }
            shape.fill(LinearGradient(colors: [p.shellTop, p.shellBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(clear ? 0.75 : 1)
            shape.fill(RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0)], center: UnitPoint(x: 0.3, y: 0.12),
                                      startRadius: 0, endRadius: size.width * 0.55)).blendMode(.screen)
            shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.28), .init(color: .white.opacity(clear ? 0.20 : 0.12), location: 0.36),
                                              .init(color: .white.opacity(0), location: 0.46)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if !clear { Grain(density: 0.45).clipShape(shape).opacity(0.35) }
            // Edge lighting: lit upper-left bevel, shaded lower-right, then a darker rim.
            shape.inset(by: 3).stroke(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .black.opacity(0.28)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3).blur(radius: 1.2)
            shape.strokeBorder(Color.black.opacity(0.32), lineWidth: 1.6)
        }
        .frame(width: size.width, height: size.height)
        // Recessed screen bezel: a well cut into the shell (dark lip above, light lip below) with an inner shadow.
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [.black.opacity(0.35), .white.opacity(0.25)], startPoint: .top, endPoint: .bottom))
            .frame(width: bz.width + 6, height: bz.height + 6).position(x: bz.midX, y: bz.midY)
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.8), lineWidth: 6).blur(radius: 4).offset(y: 2)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            .frame(width: bz.width, height: bz.height).position(x: bz.midX, y: bz.midY)
        Text("TwinPlay").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.2)
            .foregroundStyle(Color.white.opacity(0.35))
            .position(x: bz.midX, y: (layout.top.maxY + bz.maxY) / 2)
        // MENU: the movable MENU pill is drawn (and saved per skin) by the game view.
        // Speaker: plain rectangular grille of punched holes in a recessed panel (no logo).
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(darkBody ? 0.25 : 0.10))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.35), lineWidth: 1.2).blur(radius: 0.6).offset(y: 0.6).clipShape(RoundedRectangle(cornerRadius: 4)))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(darkBody ? 0.12 : 0.45), lineWidth: 0.6).offset(y: 0.8))
                .frame(width: 54, height: 34)
            VStack(spacing: 4) { ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 4) { ForEach(0..<6, id: \.self) { _ in
                    Circle().fill(RadialGradient(colors: [Color.black.opacity(0.85), Color.black.opacity(0.5)], center: UnitPoint(x: 0.5, y: 0.35), startRadius: 0, endRadius: 2))
                        .overlay(Circle().stroke(Color.white.opacity(darkBody ? 0.18 : 0.55), lineWidth: 0.5).offset(y: 0.6))
                        .frame(width: 3.4, height: 3.4)
                } }
            } }
        }
        .position(sp.speaker)
    }
}

// MARK: - DS reference shell (#9)

/// The DS skins redrawn after the reference art (ds-skin-ref: portrait, landscape, closed lid):
/// an upper half and a lower half meeting at a full-width L / MIC / R hinge bar, shell-coloured
/// raised screen surrounds, two 2x3 speaker grilles beside the top screen, LEDs on the bar, round
/// START / SELECT / MENU (drawn by the controls) and TwinPlay's mark between X / Y / A / B. Every
/// DS colour uses it; the clear ones show the insides through tinted plastic.
extension RealisticShell {
    private var darkShell: Bool { luminance(p.shellTop) < 0.45 }
    private var clear: Bool { lid.translucent }

    /// Raised screen surround: the shell colour a little lighter, a thin dark inner lip.
    @ViewBuilder fileprivate func refBezel(_ r: CGRect, margin m: CGFloat, radius: CGFloat) -> some View {
        let f = r.insetBy(dx: -m, dy: -m)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(phatDS ? p.bezel : p.shellTop)
            shape.fill(LinearGradient(colors: [.white.opacity(darkShell || phatDS ? 0.10 : 0.30), .white.opacity(darkShell || phatDS ? 0.03 : 0.10)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(darkShell ? 0.25 : 0.85), .black.opacity(0.16)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
        }
        .shadow(color: .black.opacity(0.20), radius: 2.5, y: 1.5)
        .frame(width: f.width, height: f.height).position(x: f.midX, y: f.midY)
        // Dark rim right around the picture.
        RoundedRectangle(cornerRadius: 2).fill(Color.black)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.45), lineWidth: 1.2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(darkShell ? 0.08 : 0.35), lineWidth: 0.6).padding(-1.2))
            .frame(width: r.width + 4, height: r.height + 4).position(x: r.midX, y: r.midY)
    }

    /// 2 rows x 3 widely spaced punched holes.
    fileprivate func refGrille(pitchX: CGFloat, pitchY: CGFloat, dot: CGFloat) -> some View {
        VStack(spacing: pitchY - dot) { ForEach(0..<2, id: \.self) { _ in
            HStack(spacing: pitchX - dot) { ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Color.black.opacity(darkShell ? 0.85 : 0.78))
                    .overlay(Circle().stroke(Color.white.opacity(darkShell ? 0.12 : 0.55), lineWidth: 0.5).offset(y: 0.6))
                    .frame(width: dot, height: dot)
            } }
        } }
    }

    /// Full-width hinge bar: end segments (L / R, the controls draw their caps on top), a middle
    /// cylinder with the microphone slit and "MIC." and the two LEDs.
    @ViewBuilder fileprivate func refBar(y: CGFloat, height h: CGFloat, x0: CGFloat, x1: CGFloat, endW: CGFloat, labels: Bool) -> some View {
        refBarBody(y: y, height: h, x0: x0, x1: x1, endW: endW, labels: labels)
        // Heritage camera model: the inner camera lens in the middle of the hinge.
        if camDS { cameraLens(d: min(h * 0.62, 14)).position(x: (x0 + x1) / 2, y: y) }
    }

    @ViewBuilder private func refBarBody(y: CGFloat, height h: CGFloat, x0: CGFloat, x1: CGFloat, endW: CGFloat, labels: Bool) -> some View {
        let w = x1 - x0
        let cyl = LinearGradient(stops: [.init(color: p.shellBottom, location: 0), .init(color: .white.opacity(darkShell ? 0.35 : 0.9), location: 0.28),
                                         .init(color: p.shellTop, location: 0.55), .init(color: p.shellBottom, location: 0.85),
                                         .init(color: .black.opacity(0.25), location: 1)], startPoint: .top, endPoint: .bottom)
        // Shadow the bar casts and the base colour under the gradient.
        RoundedRectangle(cornerRadius: h * 0.45, style: .continuous).fill(p.shellBottom)
            .overlay(RoundedRectangle(cornerRadius: h * 0.45, style: .continuous).fill(cyl))
            .overlay(RoundedRectangle(cornerRadius: h * 0.45, style: .continuous).strokeBorder(Color.black.opacity(0.18), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.28), radius: 3, y: 2.5)
            .frame(width: w, height: h).position(x: (x0 + x1) / 2, y: y)
        // Joints between the middle segment and the end segments.
        ForEach([x0 + endW, x1 - endW], id: \.self) { x in
            Rectangle().fill(Color.black.opacity(0.22)).frame(width: 1, height: h).position(x: x, y: y)
            Rectangle().fill(Color.white.opacity(darkShell ? 0.10 : 0.5)).frame(width: 0.8, height: h - 4).position(x: x + 1, y: y)
        }
        if labels {
            Text("L").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(ink(0.4)).position(x: x0 + endW / 2, y: y)
            Text("R").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(ink(0.4)).position(x: x1 - endW / 2, y: y)
        }
        // Microphone: a short black slit and its label.
        let micX = x0 + w * (camDS ? 0.40 : 0.476)
        RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.9)).frame(width: 3, height: h * 0.42)
            .position(x: micX, y: y)
        Text("MIC.").font(.system(size: 8, weight: .medium, design: .rounded)).tracking(0.6).foregroundStyle(ink(0.38))
            .position(x: micX + (camDS ? -18 : 18), y: y)
        // Power (green) and charge (gray, off) LEDs: two short vertical bars.
        HStack(spacing: 3.5) {
            RoundedRectangle(cornerRadius: 1).fill(Color(white: darkShell ? 0.45 : 0.62)).frame(width: 3, height: h * 0.5)
            RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.25, green: 0.85, blue: 0.30)).frame(width: 3, height: h * 0.5)
                .shadow(color: Color(red: 0.3, green: 1, blue: 0.35).opacity(0.9), radius: 2.5)
        }
        .position(x: x0 + w * 0.782, y: y)
    }

    private func ink(_ o: Double) -> Color { darkShell ? Color.white.opacity(o + 0.15) : Color.black.opacity(o) }

    /// Fully open iPhone Duo: the exact reference layout.
    @ViewBuilder var refTwinShell: some View {
        let w = size.width, h = size.height
        let bar = DualScreenLayout.twinBar(hinge: layout.hinge)
        let barH = max(bar.height + 8, h * 0.034)
        let sp = layout.twinSpots
        let a = layout.controlsArea
        let x0 = min(a.minX, 2), x1 = max(a.maxX, w - 2)
        let endW = sp.endWidth + (a.minX - x0)
        let R = min(w, h) * 0.05
        let upper = CGRect(x: 2, y: 2, width: w - 4, height: bar.midY - 2)
        let lower = CGRect(x: 2, y: bar.midY, width: w - 4, height: h - 2 - bar.midY)
        let top = layout.top, bot = layout.bottom
        if clear { ClearInsides(size: size, bar: bar).clipShape(RoundedRectangle(cornerRadius: R, style: .continuous)) }
        // Lower half (behind), then the upper half overlapping the bar's top edge.
        refHalf(CornerRect(tl: 4, tr: 4, bl: R, br: R), rect: lower, colors: [p.shellBottom, p.shellBottom], highlight: 0.10)
        refHalf(CornerRect(tl: R, tr: R, bl: 3, br: 3), rect: upper, colors: [p.shellTop, p.shellTop], highlight: 0.24)
        // Dark gaps between the upper half and the L / R end segments.
        ForEach([x0 + endW / 2, x1 - endW / 2], id: \.self) { x in
            Rectangle().fill(Color.black.opacity(clear ? 0.5 : 0.82)).frame(width: endW, height: 7).position(x: x, y: bar.midY - barH / 2 - 2.5)
        }
        refBar(y: bar.midY, height: barH, x0: x0, x1: x1, endW: endW, labels: false)
        refBezel(top, margin: max(10, top.width * 0.058), radius: 12)
        refBezel(bot, margin: max(7, bot.width * 0.032), radius: 9)
        // Speakers beside the top screen, a little above its middle.
        ForEach([w * 0.12, w * 0.88], id: \.self) { x in
            if phatDS { roundGrille(radius: min(w * 0.07, top.minX * 0.42)).position(x: x, y: top.midY) }
            else { refGrille(pitchX: w * 0.044, pitchY: w * 0.035, dot: max(4.2, w * 0.0075)).position(x: x, y: top.midY - top.height * 0.04) }
        }
        heritageDSExtras(top: top, bottom: bot)
    }

    /// Heritage DS touches shared by every layout: the camera model's round power button
    /// (lower-left corner) and the wide model's POWER / charge marks under the top screen.
    @ViewBuilder fileprivate func heritageDSExtras(top: CGRect, bottom: CGRect?) -> some View {
        if camDS {
            powerButton().position(x: 30, y: size.height - 30)
        }
        if phatDS && !layout.isSideBySide && top.minX > 40 && size.height > size.width {
            HStack(spacing: 5) {
                Circle().fill(Color(red: 0.3, green: 0.95, blue: 0.4)).frame(width: 4, height: 4).shadow(color: .green, radius: 2)
                Text("POWER").font(.system(size: 6, weight: .bold, design: .rounded)).foregroundStyle(ink(0.4))
            }
            .position(x: (top.maxX + size.width) / 2, y: max(top.minY + 10, 14))
        }
    }

    /// Round speaker: punched holes filling a circle (the original wide model).
    fileprivate func roundGrille(radius R: CGFloat) -> some View {
        let r = max(R, 14)
        let pitch = max(r / 4.2, 4.6), dot = pitch * 0.5
        return Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            var row = 0
            var yy = -r
            while yy <= r {
                let off = row % 2 == 0 ? 0 : pitch / 2
                var xx = -r + off
                while xx <= r {
                    if xx * xx + yy * yy <= (r - dot) * (r - dot) {
                        let rect = CGRect(x: c.x + xx - dot / 2, y: c.y + yy - dot / 2, width: dot, height: dot)
                        ctx.fill(Path(ellipseIn: rect.offsetBy(dx: 0, dy: 0.6)), with: .color(Color.white.opacity(darkShell ? 0.10 : 0.5)))
                        ctx.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(darkShell ? 0.85 : 0.7)))
                    }
                    xx += pitch
                }
                yy += pitch * 0.87; row += 1
            }
        }
        .frame(width: r * 2, height: r * 2)
    }

    private func cameraLens(d: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.black)
            Circle().fill(RadialGradient(colors: [Color(red: 0.25, green: 0.30, blue: 0.45), Color.black], center: .center, startRadius: 0, endRadius: d * 0.3))
                .frame(width: d * 0.55, height: d * 0.55)
            Circle().fill(Color.white.opacity(0.7)).frame(width: d * 0.12, height: d * 0.12).offset(x: -d * 0.1, y: -d * 0.1)
            Circle().strokeBorder(Color.white.opacity(darkShell ? 0.25 : 0.5), lineWidth: 0.8)
        }
        .frame(width: d, height: d)
    }

    /// Round power button with the standby glyph (camera model, lower-left corner).
    private func powerButton() -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(darkShell ? 0.5 : 0.25)).frame(width: 20, height: 20).blur(radius: 0.6)
            Circle().fill(p.pillFill).frame(width: 16, height: 16)
            Circle().fill(LinearGradient(colors: [.white.opacity(0.4), .clear, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom)).frame(width: 16, height: 16)
            Image(systemName: "power").font(.system(size: 7.5, weight: .bold)).foregroundStyle(ink(0.45))
            Circle().fill(Color(red: 0.35, green: 0.6, blue: 1)).frame(width: 3, height: 3).shadow(color: .blue, radius: 2).offset(x: 14, y: -8)
        }
    }

    @ViewBuilder private func refHalf(_ shape: CornerRect, rect r: CGRect, colors: [Color], highlight: Double) -> some View {
        ZStack {
            shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(colors: [.white.opacity(clear ? highlight + 0.1 : highlight), .white.opacity(0)], center: UnitPoint(x: 0.3, y: 0.1),
                                      startRadius: 0, endRadius: max(r.width, r.height) * 0.8)).blendMode(.screen)
            if matteDS { Grain(density: 0.6).clipShape(shape).opacity(0.45) }
            if clear {
                // Clear plastic: a sharp specular sweep and bright moulded edges.
                shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0.22), .init(color: .white.opacity(0.26), location: 0.30),
                                                  .init(color: .white.opacity(0), location: 0.40)], startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.inset(by: 2).strokeBorder(Color.white.opacity(0.45), lineWidth: 2.5).blur(radius: 0.8)
            }
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(darkShell ? 0.30 : 0.8), lid.edge.opacity(0.7)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1.6)
        }
        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
    }

    /// The reference look on every other layout (regular iPhone, iPad, single screen): same
    /// surrounds, grilles and L / MIC / R bar between stacked screens.
    @ViewBuilder var refDetails: some View {
        let top = layout.top, bot = layout.isSingle ? layout.top : layout.bottom
        refBezel(top, margin: max(8, min(top.width * 0.05, 18)), radius: 11)
        if !layout.isSingle { refBezel(bot, margin: max(6, min(bot.width * 0.03, 12)), radius: 8) }
        if !layout.isSideBySide && top.minX > 54 {
            let pitch = min(max(top.minX * 0.16, 9), 30)
            ForEach([top.minX / 2, (top.maxX + size.width) / 2], id: \.self) { x in
                if phatDS && size.height > size.width { roundGrille(radius: min(top.minX * 0.36, top.height * 0.3)).position(x: x, y: top.midY) }
                else { refGrille(pitchX: pitch, pitchY: pitch * 0.8, dot: 4.4).position(x: x, y: top.midY - top.height * 0.04) }
            }
        }
        heritageDSExtras(top: top, bottom: layout.isSingle ? nil : bot)
        if !layout.isSingle {
            if layout.isSideBySide { hingeBar(between: top, bot) }
            else {
                let gap = bot.minY - top.maxY
                if gap >= 14 {
                    refBar(y: (top.maxY + bot.minY) / 2, height: min(gap - 4, 30), x0: 6, x1: size.width - 6,
                           endW: (size.width - 12) * 0.1875, labels: false)
                }
            }
        }
    }
}

/// What a clear shell shows through the plastic: the dark insides, the board outline, screw
/// posts, speaker magnets and the ribbon cable through the hinge.
struct ClearInsides: View {
    let size: CGSize
    let bar: CGRect?

    var body: some View {
        Canvas { ctx, sz in
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(Color.black.opacity(0.62)))
            let line = GraphicsContext.Shading.color(Color.white.opacity(0.13))
            let w = sz.width, h = sz.height
            let mid = bar?.midY ?? h / 2
            // Boards in each half.
            ctx.stroke(Path(roundedRect: CGRect(x: w * 0.08, y: h * 0.06, width: w * 0.84, height: mid - h * 0.10), cornerRadius: 8), with: line, lineWidth: 1)
            ctx.stroke(Path(roundedRect: CGRect(x: w * 0.06, y: mid + h * 0.05, width: w * 0.88, height: h - mid - h * 0.10), cornerRadius: 8), with: line, lineWidth: 1)
            // Battery under the touch screen.
            ctx.fill(Path(roundedRect: CGRect(x: w * 0.30, y: mid + (h - mid) * 0.30, width: w * 0.40, height: (h - mid) * 0.36), cornerRadius: 5),
                     with: .color(Color.white.opacity(0.05)))
            // Screw posts.
            for pt in [CGPoint(x: 0.07, y: 0.05), CGPoint(x: 0.93, y: 0.05), CGPoint(x: 0.07, y: 0.95), CGPoint(x: 0.93, y: 0.95)] {
                let c = CGPoint(x: w * pt.x, y: h * pt.y)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(Color.white.opacity(0.18)), lineWidth: 1.4)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(Color.white.opacity(0.2)))
            }
            // Speaker magnets.
            for x in [w * 0.12, w * 0.88] {
                ctx.stroke(Path(ellipseIn: CGRect(x: x - 18, y: mid * 0.48 - 18, width: 36, height: 36)), with: .color(Color.white.opacity(0.10)), lineWidth: 2)
            }
            // Ribbon cable crossing the hinge.
            for i in 0..<6 {
                let x = w * 0.40 + CGFloat(i) * 3
                var p = Path(); p.move(to: CGPoint(x: x, y: mid - h * 0.06)); p.addLine(to: CGPoint(x: x, y: mid + h * 0.06))
                ctx.stroke(p, with: .color(Color(red: 0.9, green: 0.6, blue: 0.2).opacity(0.22)), lineWidth: 1.6)
            }
            // A few traces.
            var t = Path()
            t.move(to: CGPoint(x: w * 0.15, y: h * 0.88)); t.addLine(to: CGPoint(x: w * 0.30, y: h * 0.80)); t.addLine(to: CGPoint(x: w * 0.30, y: h * 0.70))
            t.move(to: CGPoint(x: w * 0.85, y: h * 0.12)); t.addLine(to: CGPoint(x: w * 0.70, y: h * 0.20))
            ctx.stroke(t, with: .color(Color.white.opacity(0.08)), lineWidth: 1.6)
        }
        .frame(width: size.width, height: size.height)
    }
}
