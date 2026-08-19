import QRCode from 'qrcode'

export async function loginOfferSvg(uri: string): Promise<string> {
  return QRCode.toString(uri, {
    type: 'svg',
    errorCorrectionLevel: 'M',
    margin: 1,
    width: 192,
  })
}
