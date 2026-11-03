export function parseSingleElement(html: string): Element | null {
  const template = document.createElement("template");
  template.innerHTML = html.trim();
  return template.content.firstElementChild;
}

export function hasMatchingDomShape(current: Node, desired: Node): boolean {
  if (current.nodeType !== desired.nodeType) return false;
  if (current.nodeType === 3) return true;
  if (current.nodeType !== 1) return current.isEqualNode(desired);
  const currentElement = current as Element;
  const desiredElement = desired as Element;
  if (currentElement.tagName !== desiredElement.tagName) return false;
  const currentChildren = Array.from(current.childNodes);
  const desiredChildren = Array.from(desired.childNodes);
  if (currentChildren.length !== desiredChildren.length) return false;
  return currentChildren.every((child, index) => hasMatchingDomShape(child, desiredChildren[index]!));
}

/** Updates an unchanged DOM tree in place so focused controls and their listeners survive. */
export function morphMatchingDom(current: Node, desired: Node): void {
  if (current.nodeType === 3) {
    if (current.nodeValue !== desired.nodeValue) current.nodeValue = desired.nodeValue;
    return;
  }
  if (current.nodeType !== 1) return;
  const currentElement = current as Element;
  const desiredElement = desired as Element;
  for (const attr of Array.from(currentElement.attributes)) {
    if (!desiredElement.hasAttribute(attr.name)) currentElement.removeAttribute(attr.name);
  }
  for (const attr of Array.from(desiredElement.attributes)) {
    if (currentElement.getAttribute(attr.name) !== attr.value) {
      currentElement.setAttribute(attr.name, attr.value);
    }
  }
  if (currentElement.tagName === "INPUT") {
    const currentInput = currentElement as HTMLInputElement;
    const desiredInput = desiredElement as HTMLInputElement;
    currentInput.value = desiredInput.value;
    currentInput.checked = desiredInput.checked;
  }
  const currentChildren = Array.from(current.childNodes);
  const desiredChildren = Array.from(desired.childNodes);
  currentChildren.forEach((child, index) => morphMatchingDom(child, desiredChildren[index]!));
}

export function inputKeepsDraft(input: HTMLInputElement | HTMLTextAreaElement): boolean {
  if (input.tagName === "TEXTAREA") return true;
  return !["button", "checkbox", "color", "file", "radio", "range", "reset", "submit"].includes(
    (input as HTMLInputElement).type,
  );
}

export function waitForCameraFrameGap(signal: AbortSignal, ms: number): Promise<void> {
  if (signal.aborted) return Promise.resolve();
  return new Promise((resolve) => {
    const finish = () => {
      window.clearTimeout(timer);
      signal.removeEventListener("abort", finish);
      resolve();
    };
    const timer = window.setTimeout(finish, ms);
    signal.addEventListener("abort", finish);
  });
}
