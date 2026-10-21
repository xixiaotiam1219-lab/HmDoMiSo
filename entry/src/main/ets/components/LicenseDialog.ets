@CustomDialog
export struct LicenseDialog {
  controller?: CustomDialogController;
  @Prop heading: string = '开源许可';
  @Prop content: string = '';
  build() {
    Column({space:16}) {
      Text(this.heading).fontSize(21).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
      Scroll() { Text(this.content).fontSize(12).fontColor($r('app.color.text_secondary')).copyOption(CopyOptions.InApp).width('100%'); }.layoutWeight(1).align(Alignment.Top)
      Button('关闭').height(42).width('100%').fontColor($r('app.color.on_accent')).backgroundColor($r('app.color.accent')).onClick(() => { this.controller?.close(); })
    }.width('88%').height('72%').padding(24).borderRadius(28).backgroundColor($r('app.color.card_bg'))
  }
}
