// Shipyard View — Pixel art submarine crew visualization
// Shows pipeline agents as animated crew members in a submarine cross-section.

import { CanvasRenderer } from "../canvas/renderer";
import { ShipyardScene } from "../canvas/shipyard-scene";
import type { FleetState, View } from "../types/api";

let renderer: CanvasRenderer | null = null;
let scene: ShipyardScene | null = null;

export const shipyardView: View = {
  init() {
    const container = document.getElementById("panel-shipyard");
    if (!container) return;

    container.innerHTML =
      '<div class="shipyard-canvas" style="width:100%;height:calc(100vh - 160px);position:relative;"></div>';
    const canvasContainer = container.querySelector(
      ".shipyard-canvas",
    ) as HTMLElement;

    renderer = new CanvasRenderer(canvasContainer);
    scene = new ShipyardScene();
    renderer.setScene(scene);
    renderer.start();
  },

  render(data: FleetState) {
    if (scene) scene.updateData(data);
  },

  destroy() {
    if (renderer) {
      renderer.destroy();
      renderer = null;
    }
    scene = null;
  },
};
