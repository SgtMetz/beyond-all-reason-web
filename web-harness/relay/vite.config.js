import { defineConfig } from "vite";
import { cloudflare } from "@cloudflare/vite-plugin";

// cf dev runs the Worker in the Workers runtime through this plugin
export default defineConfig({
	plugins: [cloudflare()],
});
