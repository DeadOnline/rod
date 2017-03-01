import nimx.matrixes
import nimx.types
import rod.rod_types
import rod.node
import rod.component.mesh_component
import rod.component.material
import rod.vertex_data_info
import opengl
import math


proc fillBuffers(vertCoords, texCoords, normals: var seq[float32], indices: var seq[GLushort]) =
    let segments = 15
    let segStep = 3.14 * 2.0f / float(segments * 2)
    var mR: Matrix4
    var tPos: Vector3

    for i in 0 .. segments * 2:
        vertCoords.add([ 0.0f, 1.0f, 0.0f])
        normals.add([ 0.0f, 1.0f, 0.0f])
        var tx:float32 = (1.0f / (segments.float32 * 2.0)) * (segments.float32 * 2.0 - i.float32) - (0.5f / (segments.float32 * 2.0))
        texCoords.add([tx, 0.0f])

    for i in 0 .. segments * 2:
        vertCoords.add([ 0.0f, -1.0f, 0.0f])
        normals.add([ 0.0f, -1.0f, 0.0f])
        var tx: float32 = (1.0f / (segments.float32 * 2.0)) * (segments.float32 * 2.0 - i.float32) - (0.5f / (segments.float32 * 2.0))
        texCoords.add([tx, 1.0f])

    for i in 1 .. segments:
        var startVertex = int(vertCoords.len() / 3)

        for j in 0 .. segments * 2 + 1:
            mR.loadIdentity()
            mR.rotateY(segStep * j.float32)
            mR.rotateX(segStep * i.float32)
            var vec = newVector3(0.0 ,1.0, 0.0 )
            tPos = mR * vec

            vertCoords.add([tPos.x, tPos.y, tPos.z])
            normals.add([tPos.x, tPos.y, tPos.z])
            var tx: float32 = (1.0f / (segments.float32 * 2.0)) * (segments.float32 * 2.0 - j.float32)
            var ty: float32 = (1.0f / segments.float32) * i.float32
            texCoords.add([tx, ty])

            if i == 1:
                if j != segments * 2:
                    indices.add(GLushort(startVertex + (j + 1)))
                    indices.add(j.GLushort)
                    indices.add(GLushort(startVertex + (j + 0)))

            if i == segments - 1:
                if j != segments * 2:
                    indices.add(GLushort(j + segments*2))
                    indices.add(GLushort(startVertex + (j + 1)))
                    indices.add(GLushort(startVertex + (j + 0)))

            if i != 1 and segments != 2:
                if j != segments * 2:
                    indices.add(GLushort(startVertex + (j + 1)))
                    indices.add(GLushort(startVertex - (segments * 2 + 1) + (j + 1)))
                    indices.add(GLushort(startVertex - (segments * 2 + 1) + (j + 0)))
                    indices.add(GLushort(startVertex + (j + 0)))
                    indices.add(GLushort(startVertex + (j + 1)))
                    indices.add(GLushort(startVertex - (segments * 2 + 1) + (j + 0)))


proc newSphere*(): Node =
    result = newNode("Sphere")
    let mesh = result.addComponent(MeshComponent)

    var vertCoords = newSeq[float32]()
    var texCoords = newSeq[float32]()
    var normals = newSeq[float32]()
    var indices = newSeq[GLushort]()

    fillBuffers(vertCoords, texCoords, normals, indices)

    mesh.vboData.vertInfo = newVertexInfoWithVertexData(vertCoords.len, texCoords.len, normals.len, 0)

    let stride = int32( mesh.vboData.vertInfo.stride / sizeof(GLfloat) )
    let size = int32(vertCoords.len * stride / 3)
    var vertexData = newSeq[GLfloat](size)
    for i in 0 ..< int32(vertCoords.len / 3):
        var offset = 0
        vertexData[stride * i + 0] = vertCoords[3*i + 0]
        vertexData[stride * i + 1] = vertCoords[3*i + 1]
        vertexData[stride * i + 2] = vertCoords[3*i + 2]
        mesh.checkMinMax(vertCoords[3*i + 0], vertCoords[3*i + 1], vertCoords[3*i + 2])
        offset += 3

        if texCoords.len != 0:
            vertexData[stride * i + offset + 0] = texCoords[2*i + 0]
            vertexData[stride * i + offset + 1] = texCoords[2*i + 1]
            offset += 2

        if normals.len != 0:
            vertexData[stride * i + offset + 0] = normals[3*i + 0]
            vertexData[stride * i + offset + 1] = normals[3*i + 1]
            vertexData[stride * i + offset + 2] = normals[3*i + 2]
            offset += 3

    mesh.createVBO(indices, vertexData)

    mesh.material.ambient = newColor(1.0, 1.0, 1.0, 0.2)
    mesh.material.diffuse = newColor(1.0, 1.0, 1.0, 1.0)
