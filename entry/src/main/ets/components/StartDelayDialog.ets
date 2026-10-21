@CustomDialog
export struct StartDelayDialog {
  controller?: CustomDialogController;
  @Prop initial: number = 5;
  @State value: number = 5;
  onApply: (value: number) => void = () => {};
  aboutToAppear(): void { this.value = this.initial; }
  build() {
    Column({space:20}) {
      Text('起播延迟').fontSize(21).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
      Text(this.value+' 秒').fontSize(34).fontWeight(FontWeight.Medium).fontColor($r('app.color.accent'))
      Text('原神横屏就绪后开始计时').fontSize(13).fontColor($r('app.color.text_secondary'))
      Slider({value:this.value,min:0,max:30,step:1}).selectedColor($r('app.color.accent')).onChange((value: number) => { this.value=Math.round(value); })
      Row({space:8}) {
        ForEach([0,3,5,10],(seconds: number) => {
          Button(seconds+' 秒').layoutWeight(1).height(34).fontSize(12).fontColor($r('app.color.accent')).backgroundColor($r('app.color.accent_soft')).onClick(() => { this.value=seconds; })
        })
      }.width('100%')
      Row({space:12}) {
        Button('取消').layoutWeight(1).height(42).fontColor($r('app.color.text_secondary')).backgroundColor($r('app.color.control_bg')).onClick(() => { this.controller?.close(); })
        Button('确定').layoutWeight(1).height(42).fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent')).onClick(() => { this.onApply(this.value); this.controller?.close(); })
      }.width('100%')
    }.width('88%').padding(24).borderRadius(28).backgroundColor($r('app.color.card_bg'))
  }
}
