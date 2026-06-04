# Example Gallery

The live gallery is generated from `examples/example_gallery.jl` during the
documentation build and published with the docs site.

```@raw html
<p><a id="threejl-gallery-link" href="assets/gallery/example_gallery.html">Open the live gallery</a></p>
<iframe
  id="threejl-gallery-frame"
  src="assets/gallery/example_gallery.html"
  title="Three.jl Example Gallery"
  style="width:100%; min-height:760px; border:1px solid var(--documenter-border-color); border-radius:6px;"
  loading="lazy">
</iframe>
<script>
(function () {
  var base = typeof documenterBaseURL === "string" ? documenterBaseURL : ".";
  var path = base.replace(/\/$/, "") + "/assets/gallery/example_gallery.html";
  document.getElementById("threejl-gallery-link").href = path;
  document.getElementById("threejl-gallery-frame").src = path;
})();
</script>
```
