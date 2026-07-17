/** Palworld 1.0 world → map texture projection (DT_WorldMapUIData bounds). */

export const MAP_SIZE = 8192

export type MapArea = 'MainMap' | 'Tree'

type AreaBounds = {
  texture: string
  min: { x: number; y: number }
  max: { x: number; y: number }
}

/**
 * Tree listed first: World Map priority 1 where rectangles overlap.
 * Textures live under /maps/.
 */
export const MAP_AREAS: Record<MapArea, AreaBounds> = {
  Tree: {
    texture: '/maps/palworld-treemap.webp',
    min: { x: 347351.5, y: -818197.0 },
    max: { x: 689148.5, y: -476400.0 },
  },
  MainMap: {
    texture: '/maps/palworld-map.webp',
    min: { x: -1099400.0, y: -724400.0 },
    max: { x: 349400.0, y: 724400.0 },
  },
}

export const MAP_AREA_ORDER: MapArea[] = ['MainMap', 'Tree']
export const DEFAULT_MAP_AREA: MapArea = 'MainMap'

const TRANSLATION_X = 123930.0
const TRANSLATION_Y = 157935.0
const SCALE = 459.0

function clamp01(n: number): number {
  return Math.min(1, Math.max(0, n))
}

export function cmPerPx(area: MapArea): number {
  const { min, max } = MAP_AREAS[area]
  return (max.x - min.x) / MAP_SIZE
}

/** OpenLayers-style y-up pixel on the 8192² texture. */
export function worldToPixel(
  worldX: number,
  worldY: number,
  area: MapArea,
): [number, number] {
  const { min } = MAP_AREAS[area]
  const cm = cmPerPx(area)
  return [(worldY - min.y) / cm, (worldX - min.x) / cm]
}

export function mapOf(worldX: number, worldY: number): MapArea | null {
  for (const area of Object.keys(MAP_AREAS) as MapArea[]) {
    const { min, max } = MAP_AREAS[area]
    if (
      worldX >= min.x &&
      worldX <= max.x &&
      worldY >= min.y &&
      worldY <= max.y
    ) {
      return area
    }
  }
  return null
}

/** UV in [0,1], v flipped for canvas y-down. */
export function worldToUv(
  worldX: number,
  worldY: number,
  area: MapArea,
): { u: number; v: number } {
  const [px, py] = worldToPixel(worldX, worldY, area)
  return {
    u: clamp01(px / MAP_SIZE),
    v: clamp01(1 - py / MAP_SIZE),
  }
}

export function projectWorld(
  worldX: number,
  worldY: number,
): { area: MapArea; u: number; v: number } {
  const area = mapOf(worldX, worldY) ?? DEFAULT_MAP_AREA
  return { area, ...worldToUv(worldX, worldY, area) }
}

/** In-game map readout numbers (tooltip-style). */
export function worldToMap(x: number, y: number): { mapX: number; mapY: number } {
  return {
    mapX: Math.round((y - TRANSLATION_Y) / SCALE),
    mapY: Math.round((x + TRANSLATION_X) / SCALE),
  }
}

export function worldDist2(
  ax: number,
  ay: number,
  bx: number,
  by: number,
): number {
  const dx = ax - bx
  const dy = ay - by
  return dx * dx + dy * dy
}

export function findNearestMarkerId(
  markers: Array<{ id: string; x: number; y: number }>,
  x: number,
  y: number,
  maxDist = 12_000,
): string | null {
  const max2 = maxDist * maxDist
  let bestId: string | null = null
  let best2 = max2
  for (const m of markers) {
    const d2 = worldDist2(m.x, m.y, x, y)
    if (d2 <= best2) {
      best2 = d2
      bestId = m.id
    }
  }
  return bestId
}
