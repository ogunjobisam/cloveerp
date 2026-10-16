// The build config, hand-rolled after Lovable was retired (it previously came
// from @lovable.dev/vite-tanstack-config, a package served only from Lovable's
// private registry). This composes the same production plugins that wrapper did,
// in the same order, and the same Cloudflare build output — dropping only the
// Lovable editor-preview dev features (sandbox port detection, HMR gate,
// dev-server bridge, asset proxy), which no longer apply.
//
//   - tailwindcss        Tailwind 4, Vite plugin
//   - tsConfigPaths      the `@/*` path alias from tsconfig.json
//   - tanstackStart      TanStack Start; SSR server entry redirected to
//                        src/server.ts (our error wrapper)
//   - nitro              the Cloudflare-module build → .output/. nitro reads
//                        wrangler.jsonc at build time, so the Worker keeps its
//                        nodejs_compat flag and app.yml deploys the same output.
//   - viteReact          React (after tanstackStart, as the wrapper had it)
//
// CSS uses lightningcss and React/TanStack are de-duped, matching the wrapper.
import { defineConfig } from "vite";
import tailwindcss from "@tailwindcss/vite";
import tsConfigPaths from "vite-tsconfig-paths";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import { nitro } from "nitro/vite";
import viteReact from "@vitejs/plugin-react";

export default defineConfig({
  css: { transformer: "lightningcss" },
  resolve: {
    alias: { "@": `${process.cwd()}/src` },
    dedupe: [
      "react",
      "react-dom",
      "react/jsx-runtime",
      "react/jsx-dev-runtime",
      "@tanstack/react-query",
      "@tanstack/query-core",
    ],
  },
  optimizeDeps: {
    include: [
      "react",
      "react-dom",
      "react-dom/client",
      "react/jsx-runtime",
      "react/jsx-dev-runtime",
    ],
  },
  plugins: [
    tailwindcss(),
    tsConfigPaths({ projects: ["./tsconfig.json"] }),
    tanstackStart({ server: { entry: "server" } }),
    nitro({ preset: "cloudflare-module" }),
    viteReact(),
  ],
});
