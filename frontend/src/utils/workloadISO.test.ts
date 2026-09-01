import { describe, expect, test } from 'bun:test'
import { attachableISOImages, attachedISOIds } from './workloadISO'

describe('Workload details Attach ISO', () => {
  const fedora = { id: 'iso-fedora', imageType: 'iso', status: 'ready' }
  const downloading = { id: 'iso-dl', imageType: 'iso', status: 'downloading' }
  const cloud = { id: 'img-cloud', imageType: 'cloud-image', status: 'ready' }
  const attached = { id: 'iso-attached', imageType: 'iso', status: 'ready' }

  test('lists ready ISOs from that Device Library excluding attached', () => {
    const listed = attachableISOImages(
      [fedora, downloading, cloud, attached],
      attachedISOIds({ isoIds: ['iso-attached'] }),
    )
    expect(listed.map((image) => image.id)).toEqual(['iso-fedora'])
  })

  test('isoIds wins over legacy isoId', () => {
    expect(attachedISOIds({ isoId: 'iso-legacy', isoIds: ['iso-1', 'iso-2'] })).toEqual([
      'iso-1',
      'iso-2',
    ])
    expect(attachedISOIds({ isoId: 'iso-legacy', isoIds: null })).toEqual(['iso-legacy'])
    expect(attachedISOIds({ isoIds: [] })).toEqual([])
    expect(attachedISOIds(null)).toEqual([])
  })

  test('cloud images and in-flight ISOs are not attachable', () => {
    expect(attachableISOImages([cloud, downloading], []).map((image) => image.id)).toEqual([])
  })
})
