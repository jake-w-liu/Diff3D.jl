# Example Gallery

The live gallery is generated from `examples/example_gallery.jl` during the
documentation build and published with the docs site.

```@raw html
<p><a id="diff3d-gallery-link" href="assets/gallery/example_gallery.html">Open the live gallery</a></p>
<iframe
  id="diff3d-gallery-frame"
  src="assets/gallery/example_gallery.html"
  title="Diff3D.jl Example Gallery"
  style="width:100%; min-height:760px; border:1px solid var(--documenter-border-color); border-radius:6px;"
  loading="lazy">
</iframe>
<script>
(function () {
  var base = typeof documenterBaseURL === "string" ? documenterBaseURL : ".";
  var version = Date.parse(document.lastModified || "") || Date.now();
  var path = base.replace(/\/$/, "") + "/assets/gallery/example_gallery.html?v=" + encodeURIComponent(String(version));
  document.getElementById("diff3d-gallery-link").href = path;
  document.getElementById("diff3d-gallery-frame").src = path;
})();
</script>
```
