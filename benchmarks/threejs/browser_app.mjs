import * as THREE from 'three';

const {fixture, scene: input} = window.__benchmarkInput;
const geometry = new THREE.BufferGeometry();
geometry.setAttribute('position', new THREE.Float32BufferAttribute(input.positions, 3));
geometry.setAttribute('normal', new THREE.Float32BufferAttribute(input.normals, 3));
geometry.setIndex(input.indices);
const material = new THREE.MeshBasicMaterial({color: new THREE.Color().setRGB(...fixture.color), toneMapped: false});
const scene = new THREE.Scene();
scene.background = new THREE.Color().setRGB(...fixture.background);
const tracks = [];
if (input.mode === 'instanced') {
    const mesh = new THREE.InstancedMesh(geometry, material, input.count);
    const matrix = new THREE.Matrix4();
    for (let i = 0; i < input.count; i++) {
        matrix.makeTranslation(...input.centers.slice(3 * i, 3 * i + 3));
        mesh.setMatrixAt(i, matrix);
    }
    mesh.instanceMatrix.needsUpdate = true;
    scene.add(mesh);
} else {
    for (let i = 0; i < input.count; i++) {
        const mesh = new THREE.Mesh(geometry, material);
        mesh.name = `triangle_${i + 1}`;
        const center = input.centers.slice(3 * i, 3 * i + 3);
        mesh.position.fromArray(center);
        scene.add(mesh);
        if (input.mode === 'dynamic') {
            const raised = [center[0], center[1] + input.amplitude, center[2]];
            tracks.push(new THREE.VectorKeyframeTrack(`${mesh.name}.position`, [0, 1, 2], [...center, ...raised, ...center]));
        }
    }
}
const mixer = new THREE.AnimationMixer(scene);
if (tracks.length) mixer.clipAction(new THREE.AnimationClip('translation', 2, tracks)).play();
const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 10);
camera.position.set(0, 0, 2);
camera.lookAt(0, 0, 0);
const renderer = new THREE.WebGLRenderer({antialias: false, alpha: false, preserveDrawingBuffer: true});
renderer.setPixelRatio(1);
renderer.setSize(fixture.width, fixture.height);
renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
renderer.toneMapping = THREE.NoToneMapping;
document.body.appendChild(renderer.domElement);
let previous;
function frame(now) {
    const delta = previous === undefined ? 0 : Math.min(0.08, Math.max(0, (now - previous) / 1000));
    previous = now;
    mixer.update(delta);
    renderer.render(scene, camera);
    requestAnimationFrame(frame);
}
window.__threeBenchmark = {revision: THREE.REVISION, objectCount: scene.children.length,
    animationTime: () => mixer.time};
requestAnimationFrame(frame);
