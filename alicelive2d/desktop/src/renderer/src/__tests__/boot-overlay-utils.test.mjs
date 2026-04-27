import test from "node:test";
import assert from "node:assert/strict";

import {
  ensureBootOverlay,
  hideBootOverlay,
} from "../boot-overlay-utils.ts";

function createFakeElement(tagName, ownerDocument) {
  return {
    tagName,
    ownerDocument,
    id: "",
    innerHTML: "",
    style: {},
    parentNode: null,
    children: [],
    appendChild(child) {
      child.parentNode = this;
      this.children.push(child);
      return child;
    },
    remove() {
      if (!this.parentNode) {
        return;
      }
      this.parentNode.children = this.parentNode.children.filter((child) => child !== this);
      this.parentNode = null;
    },
  };
}

function createFakeDocument() {
  const document = {
    elementsById: new Map(),
    body: null,
    createElement(tagName) {
      return createFakeElement(tagName, document);
    },
    getElementById(id) {
      return document.elementsById.get(id) || null;
    },
  };

  const body = createFakeElement("body", document);
  body.appendChild = function appendChild(child) {
    child.parentNode = body;
    body.children.push(child);
    if (child.id) {
      document.elementsById.set(child.id, child);
    }
    return child;
  };
  document.body = body;
  return document;
}

test("ensureBootOverlay mounts an overlay outside the React root and leaves root content untouched", () => {
  const document = createFakeDocument();
  const root = createFakeElement("div", document);
  root.id = "root";
  root.innerHTML = "<div>react tree</div>";
  document.elementsById.set("root", root);
  document.body.appendChild(root);

  const overlay = ensureBootOverlay(document, {
    status: "loading",
    message: "booting",
  });

  assert.equal(root.innerHTML, "<div>react tree</div>");
  assert.equal(overlay.id, "boot-overlay");
  assert.equal(document.body.children.includes(overlay), true);
  assert.equal(document.body.children[0], root);
});

test("hideBootOverlay removes only the overlay node", () => {
  const document = createFakeDocument();
  const root = createFakeElement("div", document);
  root.id = "root";
  document.elementsById.set("root", root);
  document.body.appendChild(root);

  const overlay = ensureBootOverlay(document, {
    status: "error",
    message: "boom",
  });
  hideBootOverlay(document);

  assert.equal(document.body.children.includes(root), true);
  assert.equal(document.body.children.includes(overlay), false);
});
