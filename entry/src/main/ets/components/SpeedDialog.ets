@CustomDialog
export struct SpeedDialog {
  controller?: CustomDialogController;
  @Prop initial: number = 1;
  @State value: number = 1;
  onApply: (value: number) => void = () => {};
  aboutToAppear(): void { this.value=this.initial; }
  build() {
    Column({space:20}) {
      Text('播放速度').fontSize(21).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
      Text(this.value.toFixed(2)+'×').fontSize(34).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
      Slider({value:this.value,min:0.5,max:1.5,step:0.05}).selectedColor($r('app.color.accent')).onChange((value: number) => { this.value=value; })
      Row({space:8}) {
        Button('0.75×').layoutWeight(1).height(34).fontSize(12).fontColor($r('app.color.text_secondary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.value=0.75; })
        Button('恢复 1×').layoutWeight(1).height(34).fontSize(12).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.value=1; })
        Button('1.25×').layoutWeight(1).height(34).fontSize(12).fontColor($r('app.color.text_secondary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.value=1.25; })
      }.width('100%')
      Row({space:12}) {
        Button('取消').layoutWeight(1).height(42).fontColor($r('app.color.text_secondary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.controller?.close(); })
        Button('确定').layoutWeight(1).height(42).fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent')).onClick(() => { this.onApply(this.value); this.controller?.close(); })
      }.width('100%')
    }.width('88%').padding(24).borderRadius(28).backgroundColor($r('app.color.card_bg'))
  }
}
