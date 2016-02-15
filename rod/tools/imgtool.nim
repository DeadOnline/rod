import nimPNG
import os, osproc, json, strutils, times, sequtils, tables, algorithm, math

import nimx.rect_packer
import nimx.types
import nimx.pathutils

import imgtools.imgtools

type Rect = imgtools.Rect
type Point = tuple[x, y: int32]
type Size = tuple[width, height: int]

const consumeLessMemory = defined(windows)

type
    SpriteSheetImage = ref object
        imageIndex: int # Index of this image in tool.images array
        spriteSheet: SpriteSheet # Index of sprite sheet in tool.images array
        srcBounds: Rect
        actualBounds: Rect
        originalPath: string
        srcSize: Size
        targetSize: Size
        pos: Point
        png: PNGResult
        parentComposition, parentNode, parentComponent: JsonNode
        frameIndex: int

    SpriteSheet = ref object
        index: int # Index of sprite sheet in tool.images array
        images: seq[SpriteSheetImage]
        packer: RectPacker

proc newSpriteSheetImage(path: string): SpriteSheetImage =
    result.new()
    result.originalPath = path

proc newSpriteSheet(minSize: Size): SpriteSheet =
    result.new()
    let px = max(nextPowerOfTwo(minSize.width), 1024)
    let py = max(nextPowerOfTwo(minSize.height), 1024)
    result.packer = newPacker(px.int32, py.int32)
    result.packer.maxX = px.int32
    result.packer.maxY = py.int32
    result.images = newSeq[SpriteSheetImage]()

type ImgTool* = ref object
    compositionPaths*: seq[string]
    compositions: seq[JsonNode]
    outPrefix*: string #
    originalResPath*: string #
    resPath*: string #
    compressOutput*: bool
    images: Table[string, SpriteSheetImage]
    spriteSheets: seq[SpriteSheet]

    latestOriginalModificationDate: Time


proc newImgTool*(): ImgTool =
    result.new()
    result.images = initTable[string, SpriteSheetImage]()
    result.spriteSheets = newSeq[SpriteSheet]()

proc withSpriteNodes(n: JsonNode, p: proc(j, s: JsonNode)) =
    let components = n["components"]
    if not components.isNil:
        let sprite = components["Sprite"]
        if not sprite.isNil:
            p(n, sprite)
    let children = n["children"]
    if not children.isNil:
        for c in children:
            withSpriteNodes(c, p)

proc tryPackImage(ss: SpriteSheet, im: SpriteSheetImage): bool =
    im.pos = ss.packer.packAndGrow(im.targetSize.width.int32, im.targetSize.height.int32)
    result = im.pos.hasSpace
    if result:
        ss.images.add(im)
        im.spriteSheet = ss

proc composeAndWrite(tool: ImgTool, ss: SpriteSheet, path: string) =
    var data = newString(ss.packer.width * ss.packer.height * 4)
    for im in ss.images:
        if im.png.isNil:
            im.png = loadPNG32(im.originalPath)

        if im.srcSize == im.targetSize:
            blitImage(
                data, ss.packer.width, ss.packer.height, # Target image
                im.pos.x, im.pos.y, # Position in target image
                im.png.data, im.png.width, im.png.height,
                im.srcBounds.x, im.srcBounds.y, im.srcBounds.width, im.srcBounds.height)
        else:
            resizeImage(im.png.data, im.png.width, im.png.height,
                data, ss.packer.width, ss.packer.height,
                im.srcBounds.x, im.srcBounds.y, im.srcBounds.width, im.srcBounds.height,
                im.pos.x, im.pos.y, im.targetSize.width, im.targetSize.height)

        im.png = nil # We no longer need the data in memory

    discard savePNG32(path, data, ss.packer.width, ss.packer.height)
    if tool.compressOutput:
        discard execCmd("pngquant --force --speed 1 -o " & path & " " & path)

    when consumeLessMemory:
        GC_fullCollect()

proc adjustTranslationValueForFrame(trans: JsonNode, im: SpriteSheetImage): JsonNode =
    result = trans
    if result.isNil:
        result = %*[im.srcBounds.x, im.srcBounds.y, 0]
    else:
        result.elems[0] = %(result[0].getFNum() + im.srcBounds.x.float)
        result.elems[1] = %(result[1].getFNum() + im.srcBounds.y.float)

proc translationAnimFromFrameAnim(node, frameAnim: JsonNode): JsonNode =
    result = newJObject()
    let values = newJArray()
    let vl = frameAnim["values"].len

    let translation = node["translation"]
    var tx, ty, tz: float
    if not translation.isNil:
        tx = translation[0].getFNum()
        ty = translation[1].getFNum()
        tz = translation[2].getFNum()

    for i in 0 ..< vl:
        #values.add(%*[tx, ty, tz]) # TODO: Fix this
        values.add(%*[0, 0, 0])

    result["values"] = values

    result["duration"] = frameAnim["duration"]
    result["frameLerp"] = %false
    let numLoops = frameAnim["numberOfLoops"]
    if not numLoops.isNil:
        result["numberOfLoops"] = numLoops

proc destPath(tool: ImgTool, origPath: string): string =
    let relPath = relativePathToPath(tool.originalResPath, origPath)
    result = tool.resPath / relPath

proc adjustImageNode(tool: ImgTool, im: SpriteSheetImage, compPath: string): JsonNode =
    # Fixup the fileName node to contain spritesheet filename and texCoords
    result = newJObject()
    doAssert(not im.spriteSheet.isNil)
    result["file"] = %relativePathToPath(tool.destPath(compPath), tool.resPath / tool.outPrefix & $im.spriteSheet.index & ".png")
    let w = im.spriteSheet.packer.width.float
    let h = im.spriteSheet.packer.height.float
    result["tex"] = %*[(im.pos.x.float + 0.5) / w, (im.pos.y.float + 0.5) / h, ((im.pos.x + im.targetSize.width).float + 0.5) / w, ((im.pos.y + im.targetSize.height).float + 0.5) / h]
    result["size"] = %*[im.srcSize.width, im.srcSize.height]

    let jNode = im.parentNode

    if im.srcBounds.x > 0 or im.srcBounds.y > 0:
        # Node position has changed
        if im.frameIndex == 0:
            jNode["translation"] = adjustTranslationValueForFrame(jNode["translation"], im)

        # Adjust translation animations
        let allAnimations = im.parentComposition["animations"]
        let nodeName = jNode["name"].getStr(nil)
        if not nodeName.isNil and not allAnimations.isNil:
            let translationAnimName = nodeName & ".translation"
            let frameAnimName = nodeName & ".curFrame"
            for k, v in allAnimations:
                let frameAnim = v[frameAnimName]
                if not frameAnim.isNil:
                    var translationAnim = v[translationAnimName]
                    if translationAnim.isNil:
                        translationAnim = translationAnimFromFrameAnim(jNode, frameAnim)
                        v[translationAnimName] = translationAnim

                    let frameValues = frameAnim["values"]
                    for iVal in 0 ..< frameValues.len:
                        if frameValues[iVal].num == im.frameIndex:
                            let transValues = translationAnim["values"]
                            transValues.elems[iVal] = adjustTranslationValueForFrame(transValues.elems[iVal], im)
                else:
                    echo "WARNING: Something is wrong..."

proc compositionContainsAnimationForNode(jComp, jNode: JsonNode, propName: string): bool =
    let name = jNode["name"]
    if not name.isNil:
        let animations = jComp["animations"]
        if not animations.isNil:
            let animName = name.str & "." & propName
            for k, v in animations:
                for ik, iv in v:
                    if ik == animName: return true

proc recalculateSourceBounds(im: SpriteSheetImage) =
    if im.parentComposition.compositionContainsAnimationForNode(im.parentNode, "curFrame"):
        im.srcBounds = im.actualBounds
        im.srcSize.width = im.srcBounds.width
        im.srcSize.height = im.srcBounds.height

const forceDownsampleRatio = 1

proc betterDimension(d: int): int =
    let r = int(d / forceDownsampleRatio)
    result = case r
        of 257 .. 400: 256
        of 513 .. 700: 512
        of 1025 .. 1300: 1024
        else: r
    if result > 2048: result = 2048

proc recalculateTargetSize(im: SpriteSheetImage) =
    im.targetSize.width = betterDimension(im.srcSize.width)
    im.targetSize.height = betterDimension(im.srcSize.height)

proc readFile(im: SpriteSheetImage) =
    im.png = loadPNG32(im.originalPath)
    if im.png.isNil:
        echo "PNG NOT LOADED: ", im.originalPath
    im.actualBounds = imageBounds(im.png.data, im.png.width, im.png.height)

    when consumeLessMemory:
        im.png = nil

    im.srcBounds.width = im.actualBounds.x + im.actualBounds.width
    im.srcBounds.height = im.actualBounds.y + im.actualBounds.height

    im.srcSize = (im.srcBounds.width, im.srcBounds.height)
    im.targetSize = im.srcSize

proc updateLastModificationDateWithFile(tool: ImgTool, path: string) =
    let modDate = getLastModificationTime(path)
    if modDate > tool.latestOriginalModificationDate:
        tool.latestOriginalModificationDate = modDate

proc removeLeftoverFiles(tool: ImgTool) =
    for imgPath in tool.images.keys:
        removeFile(tool.destPath(imgPath))

proc run*(tool: ImgTool) =
    tool.compositions = newSeq[JsonNode](tool.compositionPaths.len)

    # Parse all compositions
    for i, c in tool.compositionPaths:
        tool.updateLastModificationDateWithFile(c)
        tool.compositions[i] = parseFile(c)

    # Init original images
    for i, c in tool.compositions:
        c.withSpriteNodes proc(n, s: JsonNode) =
            let fileNames = s["fileNames"]
            let compPath = tool.compositionPaths[i].parentDir
            for ifn in 0 ..< fileNames.len:
                let fn = fileNames[ifn]
                var absPath = compPath / fn.str
                absPath.normalizePath()
                let im = newSpriteSheetImage(absPath)
                if not im.isNil:
                    tool.updateLastModificationDateWithFile(absPath)
                    im.parentComposition = c
                    im.parentNode = n
                    im.parentComponent = s
                    im.frameIndex = ifn
                    im.imageIndex = tool.images.len
                    tool.images[absPath] = im

    # Check if destination files are newer than original files. If yes, we
    # don't need to do anything.
    var needsUpdate = not fileExists(tool.resPath / tool.outPrefix & "0.png")
    if not needsUpdate:
        for c in tool.compositionPaths:
            let dstPath = tool.destPath(c)
            if not fileExists(dstPath) or getLastModificationTime(dstPath) <= tool.latestOriginalModificationDate:
                needsUpdate = true
                break

    if needsUpdate:
        for i in tool.images.values:
            echo "Reading file: ", i.originalPath
            i.readFile()
            i.recalculateSourceBounds()
            i.recalculateTargetSize()

        when consumeLessMemory:
            GC_fullCollect()

        # Sort images by area
        var allImages = toSeq(values(tool.images))
        allImages.sort(proc(x, y: SpriteSheetImage): int =
            y.targetSize.width * y.targetSize.height - x.targetSize.width * x.targetSize.height
            )

        # Allocate spritesheets for images
        echo "Packing images..."
        for i, im in allImages:
            var done = false
            for ss in tool.spriteSheets:
                done = ss.tryPackImage(im)
                if done: break
            if not done:
                let newSS = newSpriteSheet(im.targetSize)
                done = newSS.tryPackImage(im)
                if done:
                    newSS.index = tool.spriteSheets.len
                    tool.spriteSheets.add(newSS)
                else:
                    echo "Could not pack image: ", im.originalPath

        # Blit images to spriteSheets and save them
        for i, ss in tool.spriteSheets:
            echo "Saving ", i + 1, " of ", tool.spriteSheets.len
            tool.composeAndWrite(ss, tool.resPath / tool.outPrefix & $i & ".png")

        # Readjust sprite nodes
        for i, c in tool.compositions:
            c.withSpriteNodes proc(n, s: JsonNode) =
                let fileNames = s["fileNames"]
                let compPath = tool.compositionPaths[i].parentDir
                for ifn in 0 ..< fileNames.len:
                    let fn = fileNames[ifn]
                    var absPath = compPath / fn.str
                    absPath.normalizePath()
                    let im = tool.images.getOrDefault(absPath)
                    if not im.isNil and not im.spriteSheet.isNil:
                        fileNames.elems[ifn] = tool.adjustImageNode(im, compPath)

            let dstPath = tool.destPath(tool.compositionPaths[i])
            writeFile(dstPath, c.pretty().replace(" \n", "\n"))
    else:
        echo "Everyting up to date"
    tool.removeLeftoverFiles()

proc runImgToolForCompositions*(compositionPatterns: openarray[string], outPrefix: string, compressOutput: bool = true) =
    var tool = newImgTool()

    var compositions = newSeq[string]()
    for p in compositionPatterns:
        for c in walkFiles(p):
            compositions.add(c)

    tool.compositionPaths = compositions
    tool.outPrefix = outPrefix
    tool.compressOutput = compressOutput
    let startTime = epochTime()
    tool.run()
    echo "Done. Time: ", epochTime() - startTime
