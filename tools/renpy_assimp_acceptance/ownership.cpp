// Execute actual pinned Assimp objects; no mobile gameplay is run.
#include <assimp/SceneCombiner.h>
#include <assimp/anim.h>
#include <assimp/mesh.h>
#include <cassert>
#include <iostream>

static aiMesh *mesh() {
    aiMesh *value = new aiMesh;
    value->mNumVertices = 3;
    value->mVertices = new aiVector3D[3]{{1, 2, 3}, {4, 5, 6}, {7, 8, 9}};
    value->mNumFaces = 3;
    value->mFaces = new aiFace[3];
    value->mFaces[0].mNumIndices = 3;
    value->mFaces[0].mIndices = new unsigned int[3]{0, 1, 2};
    value->mFaces[2].mNumIndices = 1;
    value->mFaces[2].mIndices = new unsigned int[1]{2};
    return value;
}

static aiMeshMorphAnim *morph() {
    aiMeshMorphAnim *value = new aiMeshMorphAnim;
    value->mNumKeys = 3;
    value->mKeys = new aiMeshMorphKey[3];
    value->mKeys[0].mTime = 5;
    value->mKeys[1].mTime = 13.25;
    value->mKeys[1].mNumValuesAndWeights = 2;
    value->mKeys[1].mValues = new unsigned int[2]{0, 3};
    value->mKeys[1].mWeights = new double[2]{0.125, 0.875};
    value->mKeys[2].mTime = 17;
    value->mKeys[2].mNumValuesAndWeights = 1;
    value->mKeys[2].mValues = new unsigned int[1]{2};
    value->mKeys[2].mWeights = new double[1]{0.6};
    return value;
}

int main() {
    for (bool source_first : {false, true}) {
        aiMesh *source = mesh();
        aiMesh *copy = nullptr;
        Assimp::SceneCombiner::Copy(&copy, source);
        assert(copy && copy->mFaces != source->mFaces);
        assert(copy->mVertices != source->mVertices);
        assert(copy->mVertices[1].y == 5);
        assert(copy->mFaces[0].mNumIndices == 3);
        assert(copy->mFaces[0].mIndices != source->mFaces[0].mIndices);
        assert(copy->mFaces[0].mIndices[2] == 2);
        assert(copy->mFaces[1].mNumIndices == 0 && copy->mFaces[1].mIndices == nullptr);
        assert(copy->mFaces[2].mIndices != source->mFaces[2].mIndices);
        copy->mFaces[0].mIndices[1] = 42;
        copy->mVertices[1].y = 73;
        assert(source->mFaces[0].mIndices[1] == 1 && source->mVertices[1].y == 5);
        if (source_first) {
            delete source;
            assert(copy->mFaces[0].mIndices[1] == 42 && copy->mVertices[1].y == 73);
            delete copy;
        } else {
            delete copy;
            assert(source->mFaces[0].mIndices[1] == 1 && source->mVertices[1].y == 5);
            delete source;
        }

        aiMeshMorphAnim *morph_source = morph();
        aiMeshMorphAnim *morph_copy = nullptr;
        Assimp::SceneCombiner::Copy(&morph_copy, morph_source);
        assert(morph_copy && morph_copy->mKeys != morph_source->mKeys);
        assert(morph_copy->mKeys[0].mTime == 5);
        assert(morph_copy->mKeys[0].mValues == nullptr && morph_copy->mKeys[0].mWeights == nullptr);
        assert(morph_copy->mKeys[1].mTime == 13.25);
        assert(morph_copy->mKeys[1].mNumValuesAndWeights == 2);
        assert(morph_copy->mKeys[1].mValues != morph_source->mKeys[1].mValues);
        assert(morph_copy->mKeys[1].mWeights != morph_source->mKeys[1].mWeights);
        assert(morph_copy->mKeys[1].mValues[1] == 3 && morph_copy->mKeys[1].mWeights[1] == 0.875);
        assert(morph_copy->mKeys[2].mTime == 17);
        assert(morph_copy->mKeys[2].mValues != morph_source->mKeys[2].mValues);
        assert(morph_copy->mKeys[2].mWeights != morph_source->mKeys[2].mWeights);
        morph_copy->mKeys[1].mValues[1] = 42;
        morph_copy->mKeys[1].mWeights[1] = 0.25;
        assert(morph_source->mKeys[1].mValues[1] == 3 && morph_source->mKeys[1].mWeights[1] == 0.875);
        if (source_first) {
            delete morph_source;
            assert(morph_copy->mKeys[1].mValues[1] == 42 && morph_copy->mKeys[1].mWeights[1] == 0.25);
            delete morph_copy;
        } else {
            delete morph_copy;
            assert(morph_source->mKeys[1].mValues[1] == 3 && morph_source->mKeys[1].mWeights[1] == 0.875);
            delete morph_source;
        }
    }
    aiMesh empty;
    aiMesh *empty_copy = nullptr;
    Assimp::SceneCombiner::Copy(&empty_copy, &empty);
    assert(empty_copy->mFaces == nullptr && empty_copy->mVertices == nullptr);
    delete empty_copy;
    aiMeshMorphAnim empty_morph;
    aiMeshMorphAnim *empty_morph_copy = nullptr;
    Assimp::SceneCombiner::Copy(&empty_morph_copy, &empty_morph);
    assert(empty_morph_copy->mKeys == nullptr);
    delete empty_morph_copy;
    std::cout << "actual SceneCombiner mesh/morph ownership PASS\n";
}
