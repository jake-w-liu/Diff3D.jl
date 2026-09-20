(() => {
    const pending = new Map();
    let next = 0;
    window.requestAnimationFrame = callback => { const id = ++next; pending.set(id, callback); return id; };
    window.cancelAnimationFrame = id => pending.delete(id);
    const resources = {};
    let calls = 0, triangles = 0;
    const wrapped = new WeakSet();
    function wrapDraw(owner, name, modeIndex, countIndex, instanceIndex = null) {
        const original = owner[name];
        if (typeof original !== 'function') return;
        owner[name] = function(...args) {
            calls++;
            if (args[modeIndex] !== 4) throw new Error('Benchmark submitted non-triangle primitives');
            triangles += args[countIndex] / 3 * (instanceIndex === null ? 1 : args[instanceIndex]);
            return original.apply(this, args);
        };
    }
    const originalContext = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function(name, attributes) {
        const webgl = ['webgl', 'webgl2', 'experimental-webgl'].includes(name);
        const context = originalContext.call(this, name, webgl ?
            {...attributes, antialias: false, alpha: false, preserveDrawingBuffer: true} : attributes);
        if (!webgl || !context || wrapped.has(context)) return context;
        if (window.__benchmarkGL) throw new Error('Benchmark unexpectedly created multiple WebGL contexts');
        wrapped.add(context);
        window.__benchmarkGL = context;
        wrapDraw(context, 'drawElements', 0, 1);
        wrapDraw(context, 'drawArrays', 0, 2);
        wrapDraw(context, 'drawElementsInstanced', 0, 1, 4);
        wrapDraw(context, 'drawArraysInstanced', 0, 2, 3);
        for (const kind of ['Buffer', 'Texture', 'Program', 'Shader', 'Framebuffer', 'Renderbuffer', 'VertexArray']) {
            for (const verb of ['create', 'delete']) {
                const key = verb + kind, original = context[key];
                if (typeof original !== 'function') continue;
                resources[key] = 0;
                context[key] = function(...args) { resources[key]++; return original.apply(this, args); };
            }
        }
        const originalExtension = context.getExtension;
        context.getExtension = function(extension) {
            const value = originalExtension.call(this, extension);
            if (extension === 'ANGLE_instanced_arrays' && value && !wrapped.has(value)) {
                wrapped.add(value);
                wrapDraw(value, 'drawElementsInstancedANGLE', 0, 1, 4);
                wrapDraw(value, 'drawArraysInstancedANGLE', 0, 2, 3);
            }
            return value;
        };
        return context;
    };
    window.__benchmarkStep = time => {
        if (pending.size !== 1) throw new Error(`Expected one renderer callback, received ${pending.size}`);
        const callback = pending.values().next().value;
        pending.clear();
        calls = 0; triangles = 0;
        const start = performance.now();
        callback(time);
        const gl = window.__benchmarkGL;
        if (!gl) throw new Error('No WebGL context');
        gl.finish();
        const elapsed = performance.now() - start;
        const error = gl.getError();
        if (error) throw new Error(`WebGL error ${error}`);
        return {milliseconds: elapsed, calls, triangles, resources: {...resources}};
    };
    window.__benchmarkPixels = () => {
        const gl = window.__benchmarkGL;
        const pixels = new Uint8Array(gl.drawingBufferWidth * gl.drawingBufferHeight * 4);
        gl.readPixels(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
        if (gl.getError()) throw new Error('Pixel readback failed');
        return Array.from(pixels);
    };
    window.__benchmarkBatch = (firstIndex, count) => {
        const frames = [], start = performance.now();
        for (let i = 0; i < count; i++) frames.push(window.__benchmarkStep(1 + (firstIndex + i) * 1000 / 60));
        return {milliseconds: performance.now() - start, frames};
    };
    window.__benchmarkEnvironment = () => {
        const gl = window.__benchmarkGL, debug = gl.getExtension('WEBGL_debug_renderer_info');
        return {version: gl.getParameter(gl.VERSION), shadingLanguage: gl.getParameter(gl.SHADING_LANGUAGE_VERSION),
            renderer: gl.getParameter(debug ? debug.UNMASKED_RENDERER_WEBGL : gl.RENDERER),
            vendor: gl.getParameter(debug ? debug.UNMASKED_VENDOR_WEBGL : gl.VENDOR),
            context: gl.getContextAttributes(), width: gl.drawingBufferWidth, height: gl.drawingBufferHeight,
            fragmentTextures: gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS),
            userAgent: navigator.userAgent, devicePixelRatio,
            animationTime: window.__diff3dDebug?.animationTime() ?? window.__threeBenchmark?.animationTime(),
            objectCount: window.__diff3dDebug?.activeObjectCount() ?? window.__threeBenchmark?.objectCount};
    };
    document.addEventListener('DOMContentLoaded', () => {
        try {
            const canvas = document.querySelector('canvas');
            if (!canvas) throw new Error('Benchmark has no canvas');
            const {width, height} = window.__benchmarkDimensions;
            canvas.style.setProperty('width', `${width}px`, 'important');
            canvas.style.setProperty('height', `${height}px`, 'important');
            canvas.style.setProperty('position', 'fixed', 'important');
            canvas.style.setProperty('top', '0', 'important');
            canvas.style.setProperty('left', '0', 'important');
            const result = window.__benchmarkStep(1);
            window.__benchmarkFirst = {...result, navigationToFirstFrameMs: performance.now()};
        } catch (error) {
            window.__benchmarkFailure = String(error.stack || error);
        }
    });
})();
