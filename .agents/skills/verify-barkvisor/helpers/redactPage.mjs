export async function redactPage(page) {
  await page.evaluate(() => {
    const re = /[\w.-]+\.ts\.net/g
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
    const nodes = []
    let node
    while ((node = walk.nextNode())) nodes.push(node)
    for (node of nodes) {
      if (re.test(node.textContent)) {
        re.lastIndex = 0
        node.textContent = node.textContent.replace(re, 'device.local')
      }
      re.lastIndex = 0
    }
    document.title = document.title.replace(re, 'device.local')
    for (const el of document.querySelectorAll('input, textarea')) {
      if (el.value && re.test(el.value)) {
        re.lastIndex = 0
        el.value = el.value.replace(re, 'device.local')
      }
      re.lastIndex = 0
    }
  })
}
