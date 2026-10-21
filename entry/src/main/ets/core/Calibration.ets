export class PixelPoint {
  x: number = 0;
  y: number = 0;
  constructor(x: number = 0, y: number = 0) { this.x = x; this.y = y; }
}
export class ImageFit {
  scale: number = 1;
  offsetX: number = 0;
  offsetY: number = 0;
  constructor(imageW: number, imageH: number, viewW: number, viewH: number, zoom: number = 1) {
    this.scale = Math.min(viewW / imageW, viewH / imageH) * zoom;
    this.offsetX = (viewW - imageW * this.scale) / 2;
    this.offsetY = (viewH - imageH * this.scale) / 2;
  }
  toImage(x: number, y: number): PixelPoint { return new PixelPoint((x - this.offsetX) / this.scale, (y - this.offsetY) / this.scale); }
  toView(p: PixelPoint): PixelPoint { return new PixelPoint(p.x * this.scale + this.offsetX, p.y * this.scale + this.offsetY); }
}
export class CalibrationProfile {
  version: number = 1;
  width: number = 0;
  height: number = 0;
  orientation: string = 'landscape';
  fullScreenshotConfirmed: boolean = false;
  corners: PixelPoint[] = [];
  adjustments: PixelPoint[] = [];
  points: PixelPoint[] = [];
  savedAt: number = 0;
}
export function resetCalibration(w: number, h: number): CalibrationProfile {
  const p = new CalibrationProfile(); p.width = w; p.height = h;
  p.corners = [new PixelPoint(w * 0.23, h * 0.53), new PixelPoint(w * 0.77, h * 0.53),
    new PixelPoint(w * 0.23, h * 0.84), new PixelPoint(w * 0.77, h * 0.84)];
  for (let i = 0; i < 21; i++) { p.adjustments.push(new PixelPoint()); }
  recalculate(p); return p;
}
export function recalculate(p: CalibrationProfile): void {
  p.points = [];
  for (let row = 0; row < 3; row++) {
    const v = row / 2;
    for (let col = 0; col < 7; col++) {
      const u = col / 6; const d = p.adjustments[row * 7 + col] || new PixelPoint();
      p.points.push(new PixelPoint(
        (1-u)*(1-v)*p.corners[0].x + u*(1-v)*p.corners[1].x + (1-u)*v*p.corners[2].x + u*v*p.corners[3].x + d.x,
        (1-u)*(1-v)*p.corners[0].y + u*(1-v)*p.corners[1].y + (1-u)*v*p.corners[2].y + u*v*p.corners[3].y + d.y));
    }
  }
}
export function validateCalibration(p: CalibrationProfile, width: number, height: number): string {
  if (!p.fullScreenshotConfirmed) { return '请确认导入的是完整、未裁剪截图'; }
  if (p.width <= p.height || p.orientation !== 'landscape') { return '请使用横屏完整截图'; }
  if (p.width !== width || p.height !== height) { return '截图尺寸与当前设备方向/分辨率不匹配，请重新校准'; }
  if (p.corners.length !== 4 || p.adjustments.length !== 21 || p.points.length !== 21) { return '校准数据不完整'; }
  const c = p.corners;
  const perimeter = [c[0], c[1], c[3], c[2]];
  for (let i = 0; i < 4; i++) {
    const a = perimeter[i]; const b = perimeter[(i+1)%4]; const d = perimeter[(i+2)%4];
    if ((b.x-a.x)*(d.y-b.y)-(b.y-a.y)*(d.x-b.x) <= 1) { return '四角交叉、翻转或间距太小，请重置'; }
  }
  for (let i = 0; i < 21; i++) {
    const a = p.points[i];
    if (!Number.isFinite(a.x) || !Number.isFinite(a.y) || a.x < 0 || a.y < 0 || a.x >= width || a.y >= height) { return '琴键坐标超出原始截图范围'; }
    for (let j = i+1; j < 21; j++) {
      const b = p.points[j]; if (Math.hypot(a.x-b.x, a.y-b.y) < 12) { return '部分琴键过近，请检查模型'; }
    }
  }
  return '';
}
