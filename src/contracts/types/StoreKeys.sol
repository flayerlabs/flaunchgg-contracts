// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * Defines a range of `tstore` storage locations that will be used for swap event storage.
 */
abstract contract StoreKeys {
    bytes32 internal constant TS_FL_AMOUNT0 = 0x17cab649bf7619b4535991407dcf8f717035632cf45997a05c0f90b7baafa479;
    bytes32 internal constant TS_FL_AMOUNT1 = 0x170e502bdc7039c895af9c291daf6592705d439a7873ee28dbc514d2f1aa51b3;
    bytes32 internal constant TS_FL_FEE0 = 0xaac705f00f1df487f4863cf5b7baa49be15a9dc73d477f33ca4d694d45cac7fe;
    bytes32 internal constant TS_FL_FEE1 = 0x2153348e08952a9737a728deab496289242e3884d90dd8e5fc8362f809e84314;

    bytes32 internal constant TS_ISP_AMOUNT0 = 0x859fad1dd1a8a0c97fb9e594529061ff17256ed2fd92004dfd6d47a8324651c4;
    bytes32 internal constant TS_ISP_AMOUNT1 = 0xee887e5283585aea7d61ae82ec91b0d9dbc7a52caa1fbc4f511651d06967058d;
    bytes32 internal constant TS_ISP_FEE0 = 0x1a426dc34b0367779dd37e66c4b193647bd2fd094d26b263dccbe93433d0a25b;
    bytes32 internal constant TS_ISP_FEE1 = 0xb5692db6de7b607ce10bbcb6a38fb443823969b63ffea1591751f25f9fe7059a;

    bytes32 internal constant TS_UNI_AMOUNT0 = 0x0f457c8132f52d9098267126b744d1c04e04ccc48dce7c5b4396b38879d8b08a;
    bytes32 internal constant TS_UNI_AMOUNT1 = 0xf5955824691119aec0d1c983542055bfb83b16d3bc8d04e6cd271bbd244e894a;
    bytes32 internal constant TS_UNI_FEE0 = 0x84457b11f2602289c00904214483ea820055ea325cc54ad9b512e76c6541dfb4;
    bytes32 internal constant TS_UNI_FEE1 = 0x6bc3f16992c8e44a3018b72b6d7aec54e64e1cdec74e64c5154c782ffe8aff2d;
}
