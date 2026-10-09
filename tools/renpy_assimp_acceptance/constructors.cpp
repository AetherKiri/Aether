// Execute actual pinned Assimp objects; no mobile gameplay is run.
#include "o3dgcCommon.h"
#include "o3dgcIndexedFaceSet.h"
#include "o3dgcSC3DMCEncodeParams.h"
#include "o3dgcTimer.h"
#include <cassert>
#include <cmath>
#include <iostream>

int main() {
    using namespace o3dgc;
    SC3DMCStats stats;
    assert(stats.m_timeCoord == 0 && stats.m_timeNormal == 0 && stats.m_timeCoordIndex == 0);
    assert(stats.m_timeReorder == 0);
    assert(stats.m_streamSizeCoord == 0 && stats.m_streamSizeNormal == 0 && stats.m_streamSizeCoordIndex == 0);
    for (unsigned long a = 0; a < O3DGC_SC3DMC_MAX_NUM_FLOAT_ATTRIBUTES; ++a) {
        assert(stats.m_timeFloatAttribute[a] == 0 && stats.m_streamSizeFloatAttribute[a] == 0);
    }
    for (unsigned long a = 0; a < O3DGC_SC3DMC_MAX_NUM_INT_ATTRIBUTES; ++a) {
        assert(stats.m_timeIntAttribute[a] == 0 && stats.m_streamSizeIntAttribute[a] == 0);
    }

    SC3DMCEncodeParams parameters;
    assert(parameters.GetNumFloatAttributes() == 0 && parameters.GetNumIntAttributes() == 0);
    assert(parameters.GetCoordQuantBits() == 14 && parameters.GetNormalQuantBits() == 8);
    assert(parameters.GetCoordPredMode() == O3DGC_SC3DMC_PARALLELOGRAM_PREDICTION);
    assert(parameters.GetNormalPredMode() == O3DGC_SC3DMC_SURF_NORMALS_PREDICTION);
    assert(parameters.GetStreamType() == O3DGC_STREAM_TYPE_ASCII);
    assert(parameters.GetEncodeMode() == O3DGC_SC3DMC_ENCODE_MODE_TFAN);
    for (unsigned long a = 0; a < O3DGC_SC3DMC_MAX_NUM_FLOAT_ATTRIBUTES; ++a) {
        assert(parameters.GetFloatAttributeQuantBits(a) == 0);
        assert(parameters.GetFloatAttributePredMode(a) == O3DGC_SC3DMC_DIFFERENTIAL_PREDICTION);
    }
    for (unsigned long a = 0; a < O3DGC_SC3DMC_MAX_NUM_INT_ATTRIBUTES; ++a) {
        assert(parameters.GetIntAttributePredMode(a) == O3DGC_SC3DMC_NO_PREDICTION);
    }

    IndexedFaceSet<unsigned short> face_set;
    assert(face_set.GetNCoordIndex() == 0 && face_set.GetNCoord() == 0 && face_set.GetNNormal() == 0);
    assert(face_set.GetNumFloatAttributes() == 0 && face_set.GetNumIntAttributes() == 0);
    assert(face_set.GetCoordIndex() == nullptr && face_set.GetIndexBufferID() == nullptr);
    assert(face_set.GetCoord() == nullptr && face_set.GetNormal() == nullptr);
    assert(face_set.GetCreaseAngle() == 30 && face_set.GetCCW() && face_set.GetSolid());
    assert(face_set.GetConvex() && face_set.GetIsTriangularMesh());
    for (int dimension = 0; dimension < 3; ++dimension) {
        assert(face_set.GetCoordMin(dimension) == 0 && face_set.GetCoordMax(dimension) == 0);
        assert(face_set.GetNormalMin(dimension) == 0 && face_set.GetNormalMax(dimension) == 0);
    }
    for (unsigned long a = 0; a < O3DGC_SC3DMC_MAX_NUM_FLOAT_ATTRIBUTES; ++a) {
        assert(face_set.GetNFloatAttribute(a) == 0 && face_set.GetFloatAttributeDim(a) == 0);
        assert(face_set.GetFloatAttributeType(a) == O3DGC_IFS_FLOAT_ATTRIBUTE_TYPE_UNKOWN);
        assert(face_set.GetFloatAttribute(a) == nullptr);
        for (unsigned long dimension = 0; dimension < O3DGC_SC3DMC_MAX_DIM_ATTRIBUTES; ++dimension) {
            assert(face_set.GetFloatAttributeMin(a, dimension) == 0);
            assert(face_set.GetFloatAttributeMax(a, dimension) == 0);
        }
    }
    for (unsigned long a = 0; a < O3DGC_SC3DMC_MAX_NUM_INT_ATTRIBUTES; ++a) {
        assert(face_set.GetNIntAttribute(a) == 0 && face_set.GetIntAttributeDim(a) == 0);
        assert(face_set.GetIntAttributeType(a) == O3DGC_IFS_INT_ATTRIBUTE_TYPE_UNKOWN);
        assert(face_set.GetIntAttribute(a) == nullptr);
    }

    Timer timer;
    assert(timer.GetElapsedTime() == 0);
    timer.Tic();
    timer.Toc();
    assert(std::isfinite(timer.GetElapsedTime()));
    std::cout << "actual Open3DGC constructor contracts PASS (host platform)\n";
}
