// generateSampleVRM.mjs — 再配布可能なサンプル VRM (VRM 1.0) をプログラムで生成する
//
//   node scripts/generateSampleVRM.mjs
//   → public/models/SampleBot.vrm
//
// 箱ポリゴンのロボット型ヒューマノイド。スキンメッシュ + VRMC_vrm 1.0 拡張付き。
// 完全に本リポジトリ発のモデルなので自由に再配布できます。
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SKELETON, BONE_NAMES } from '../src/vrmaBuilder.js';

// --- 骨格ワールド座標 (Tポーズ・回転なしなので平行移動の累積) ---
const world = {};
for (const name of BONE_NAMES) {
  const [parent, t] = SKELETON[name];
  const p = parent ? world[parent] : [0, 0, 0];
  world[name] = [p[0] + t[0], p[1] + t[1], p[2] + t[2]];
}

// --- ジオメトリ構築 ---
const positions = [];
const normals = [];
const joints = [];
const weights = [];
const primIndices = { body: [], accent: [], dark: [] };
let vertCount = 0;

const boneIndex = Object.fromEntries(BONE_NAMES.map((n, i) => [n, i]));

/** 中心 c・サイズ s の箱を bone にバインドして追加 */
function box(prim, c, s, bone) {
  const [cx, cy, cz] = c;
  const [hx, hy, hz] = [s[0] / 2, s[1] / 2, s[2] / 2];
  const bi = boneIndex[bone];
  // 面ごとに4頂点 (normal共有)
  const faces = [
    { n: [1, 0, 0],  v: [[+hx,-hy,-hz],[+hx,+hy,-hz],[+hx,+hy,+hz],[+hx,-hy,+hz]] },
    { n: [-1, 0, 0], v: [[-hx,-hy,+hz],[-hx,+hy,+hz],[-hx,+hy,-hz],[-hx,-hy,-hz]] },
    { n: [0, 1, 0],  v: [[-hx,+hy,-hz],[-hx,+hy,+hz],[+hx,+hy,+hz],[+hx,+hy,-hz]] },
    { n: [0, -1, 0], v: [[-hx,-hy,+hz],[-hx,-hy,-hz],[+hx,-hy,-hz],[+hx,-hy,+hz]] },
    { n: [0, 0, 1],  v: [[-hx,-hy,+hz],[+hx,-hy,+hz],[+hx,+hy,+hz],[-hx,+hy,+hz]] },
    { n: [0, 0, -1], v: [[+hx,-hy,-hz],[-hx,-hy,-hz],[-hx,+hy,-hz],[+hx,+hy,-hz]] },
  ];
  for (const f of faces) {
    const base = vertCount;
    for (const [x, y, z] of f.v) {
      positions.push(cx + x, cy + y, cz + z);
      normals.push(...f.n);
      joints.push(bi, 0, 0, 0);
      weights.push(1, 0, 0, 0);
      vertCount++;
    }
    primIndices[prim].push(base, base + 1, base + 2, base, base + 2, base + 3);
  }
}

const W = world;
// 胴体まわり
box('accent', [0, W.hips[1] + 0.02, 0],            [0.26, 0.16, 0.15], 'hips');
box('body',   [0, W.spine[1] + 0.06, 0],           [0.23, 0.12, 0.13], 'spine');
box('body',   [0, W.chest[1] + 0.06, 0],           [0.26, 0.13, 0.14], 'chest');
box('body',   [0, W.upperChest[1] + 0.065, 0],     [0.30, 0.14, 0.16], 'upperChest');
box('body',   [0, W.neck[1] + 0.04, 0],            [0.08, 0.09, 0.08], 'neck');
box('body',   [0, W.head[1] + 0.12, 0],            [0.24, 0.26, 0.22], 'head');
box('dark',   [0, W.head[1] + 0.14, 0.105],        [0.16, 0.07, 0.03], 'head');   // バイザー
box('accent', [-0.045, W.head[1] + 0.14, 0.122],   [0.035, 0.035, 0.01], 'head'); // 右目
box('accent', [0.045, W.head[1] + 0.14, 0.122],    [0.035, 0.035, 0.01], 'head'); // 左目

// 腕 (左 +X / 右 -X 対称)
for (const side of [1, -1]) {
  const L = side === 1 ? 'left' : 'right';
  const ua = W[`${L}UpperArm`], la = W[`${L}LowerArm`], hd = W[`${L}Hand`];
  box('body',   [(ua[0] + la[0]) / 2, ua[1], 0], [0.22, 0.09, 0.09], `${L}UpperArm`);
  box('body',   [(la[0] + hd[0]) / 2, la[1], 0], [0.20, 0.08, 0.08], `${L}LowerArm`);
  box('accent', [hd[0] + side * 0.05, hd[1], 0], [0.10, 0.08, 0.06], `${L}Hand`);
  box('accent', [ua[0] - side * 0.01, ua[1] + 0.03, 0], [0.13, 0.11, 0.12], `${L}Shoulder`);
}

// 脚
for (const side of [1, -1]) {
  const L = side === 1 ? 'left' : 'right';
  const ul = W[`${L}UpperLeg`], ll = W[`${L}LowerLeg`], ft = W[`${L}Foot`];
  box('body', [ul[0], (ul[1] + ll[1]) / 2, 0], [0.12, 0.36, 0.12], `${L}UpperLeg`);
  box('body', [ll[0], (ll[1] + ft[1]) / 2, 0], [0.10, 0.38, 0.10], `${L}LowerLeg`);
  box('dark', [ft[0], ft[1] - 0.035, 0.045],   [0.11, 0.08, 0.22], `${L}Foot`);
}

// --- glTF 構築 ---
const binParts = [];
const bufferViews = [];
const accessors = [];
let binOffset = 0;

function addBufferView(typedArray, target) {
  const pad = (4 - (binOffset % 4)) % 4;
  if (pad) {
    binParts.push(new Uint8Array(pad));
    binOffset += pad;
  }
  bufferViews.push({
    buffer: 0,
    byteOffset: binOffset,
    byteLength: typedArray.byteLength,
    ...(target ? { target } : {}),
  });
  binParts.push(new Uint8Array(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength));
  binOffset += typedArray.byteLength;
  return bufferViews.length - 1;
}

function addAccessor(typedArray, componentType, type, target, withMinMax = false) {
  const numComp = { SCALAR: 1, VEC3: 3, VEC4: 4, MAT4: 16 }[type];
  const acc = {
    bufferView: addBufferView(typedArray, target),
    componentType,
    count: typedArray.length / numComp,
    type,
  };
  if (withMinMax) {
    const min = new Array(numComp).fill(Infinity);
    const max = new Array(numComp).fill(-Infinity);
    for (let i = 0; i < typedArray.length; i += numComp) {
      for (let j = 0; j < numComp; j++) {
        min[j] = Math.min(min[j], typedArray[i + j]);
        max[j] = Math.max(max[j], typedArray[i + j]);
      }
    }
    acc.min = min;
    acc.max = max;
  }
  accessors.push(acc);
  return accessors.length - 1;
}

const ARRAY_BUFFER = 34962;
const ELEMENT_ARRAY_BUFFER = 34963;

const posAcc = addAccessor(new Float32Array(positions), 5126, 'VEC3', ARRAY_BUFFER, true);
const nrmAcc = addAccessor(new Float32Array(normals), 5126, 'VEC3', ARRAY_BUFFER);
const jntAcc = addAccessor(new Uint8Array(joints), 5121, 'VEC4', ARRAY_BUFFER);
const wgtAcc = addAccessor(new Float32Array(weights), 5126, 'VEC4', ARRAY_BUFFER);

const materials = [
  { name: 'body',   pbrMetallicRoughness: { baseColorFactor: [0.88, 0.90, 0.94, 1], metallicFactor: 0.1, roughnessFactor: 0.8 } },
  { name: 'accent', pbrMetallicRoughness: { baseColorFactor: [0.36, 0.85, 0.55, 1], metallicFactor: 0.1, roughnessFactor: 0.6 } },
  { name: 'dark',   pbrMetallicRoughness: { baseColorFactor: [0.13, 0.15, 0.20, 1], metallicFactor: 0.2, roughnessFactor: 0.5 } },
];

const primitives = ['body', 'accent', 'dark'].map((prim, mi) => ({
  attributes: { POSITION: posAcc, NORMAL: nrmAcc, JOINTS_0: jntAcc, WEIGHTS_0: wgtAcc },
  indices: addAccessor(new Uint16Array(primIndices[prim]), 5123, 'SCALAR', ELEMENT_ARRAY_BUFFER),
  material: mi,
  mode: 4,
}));

// ノード: 骨格 + メッシュ
const nodes = [];
const nodeIndex = {};
for (const name of BONE_NAMES) {
  nodeIndex[name] = nodes.length;
  nodes.push({ name: `J_${name}`, translation: [...SKELETON[name][1]] });
}
for (const name of BONE_NAMES) {
  const parent = SKELETON[name][0];
  if (parent !== null) (nodes[nodeIndex[parent]].children ??= []).push(nodeIndex[name]);
}

// inverseBindMatrices (回転なし → 平行移動の逆行列のみ)
const ibm = new Float32Array(BONE_NAMES.length * 16);
BONE_NAMES.forEach((name, i) => {
  const [x, y, z] = world[name];
  ibm.set([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -x, -y, -z, 1], i * 16);
});
const ibmAcc = addAccessor(ibm, 5126, 'MAT4');

const meshNode = nodes.length;
nodes.push({ name: 'SampleBotMesh', mesh: 0, skin: 0 });

const humanBones = {};
for (const name of BONE_NAMES) humanBones[name] = { node: nodeIndex[name] };

const json = {
  asset: { version: '2.0', generator: 'text-to-vrma sample generator' },
  extensionsUsed: ['VRMC_vrm'],
  extensions: {
    VRMC_vrm: {
      specVersion: '1.0',
      meta: {
        name: 'SampleBot',
        version: '1.0',
        authors: ['text-to-vrma project'],
        licenseUrl: 'https://vrm.dev/licenses/1.0/',
        avatarPermission: 'everyone',
        allowExcessivelyViolentUsage: true,
        allowExcessivelySexualUsage: true,
        commercialUsage: 'corporation',
        allowPoliticalOrReligiousUsage: true,
        allowAntisocialOrHateUsage: false,
        creditNotation: 'unnecessary',
        allowRedistribution: true,
        modification: 'allowModificationRedistribution',
      },
      humanoid: { humanBones },
    },
  },
  scene: 0,
  scenes: [{ nodes: [nodeIndex.hips, meshNode] }],
  nodes,
  meshes: [{ name: 'SampleBot', primitives }],
  skins: [{ joints: BONE_NAMES.map((n) => nodeIndex[n]), inverseBindMatrices: ibmAcc, skeleton: nodeIndex.hips }],
  materials,
  accessors,
  bufferViews,
  buffers: [{ byteLength: binOffset }],
};

// --- GLB パック ---
const jsonBytes = new TextEncoder().encode(JSON.stringify(json));
const jsonPad = (4 - (jsonBytes.length % 4)) % 4;
const binPad = (4 - (binOffset % 4)) % 4;
const total = 12 + 8 + jsonBytes.length + jsonPad + 8 + binOffset + binPad;
const out = Buffer.alloc(total);
let o = 0;
out.writeUInt32LE(0x46546c67, o); o += 4;
out.writeUInt32LE(2, o); o += 4;
out.writeUInt32LE(total, o); o += 4;
out.writeUInt32LE(jsonBytes.length + jsonPad, o); o += 4;
out.writeUInt32LE(0x4e4f534a, o); o += 4;
Buffer.from(jsonBytes).copy(out, o); o += jsonBytes.length;
for (let i = 0; i < jsonPad; i++) out.writeUInt8(0x20, o++);
out.writeUInt32LE(binOffset + binPad, o); o += 4;
out.writeUInt32LE(0x004e4942, o); o += 4;
for (const part of binParts) {
  Buffer.from(part.buffer, part.byteOffset, part.byteLength).copy(out, o);
  o += part.byteLength;
}

const dest = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..', 'public', 'models', 'SampleBot.vrm'
);
fs.writeFileSync(dest, out);
console.log(`written: ${dest} (${(total / 1024).toFixed(1)} KB, ${vertCount} verts)`);
