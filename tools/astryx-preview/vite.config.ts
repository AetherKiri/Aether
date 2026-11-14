import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { astryxStylex } from "@astryxdesign/build/vite";

export default defineConfig({
  // The local dependency resolves outside node_modules. Keep its component
  // styles below the Neutral theme overrides in Astryx's own CSS layers.
  plugins: [...astryxStylex({ libraryPattern: "astryx/packages/" }), react()],
  resolve: { dedupe: ["react", "react-dom", "@stylexjs/stylex"] },
  build: { rollupOptions: { input: { index: "index.html", app: "app.html" } } },
  server: { fs: { allow: ["../..", "../../../astryx"] } },
});
