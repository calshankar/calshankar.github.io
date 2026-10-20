/**
 * Wraps astro-mermaid diagrams with expand-to-lightbox + pan/zoom.
 * Moves the live SVG into the modal (no clone) to avoid duplicate id() breakage.
 */
(function () {
	const WRAP_CLASS = 'mermaid-diagram-shell';
	const PROCESSED = 'data-processed';
	const ENHANCED = 'data-mermaid-enhanced';

	let modal = null;
	let stage = null;
	let viewport = null;
	let scaleLabel = null;
	let scale = 1;
	let panX = 0;
	let panY = 0;
	let dragging = false;
	let dragStart = { x: 0, y: 0, panX: 0, panY: 0 };
	let lastFocused = null;

	/** @type {{ pre: HTMLPreElement, placeholder: Comment } | null} */
	let activeSession = null;

	const MIN_SCALE = 0.2;
	const MAX_SCALE = 5;
	const ZOOM_STEP = 0.15;

	function clamp(value, min, max) {
		return Math.min(max, Math.max(min, value));
	}

	function applyTransform() {
		if (!stage) return;
		stage.style.transform = `translate(${panX}px, ${panY}px) scale(${scale})`;
		if (scaleLabel) {
			scaleLabel.textContent = `${Math.round(scale * 100)}%`;
		}
	}

	function measureStage() {
		const svg = stage?.querySelector('svg');
		if (!svg || !viewport) return null;

		const viewBox = svg.viewBox?.baseVal;
		let w = viewBox?.width || 0;
		let h = viewBox?.height || 0;

		if (!w || !h) {
			try {
				const box = svg.getBBox();
				w = box.width;
				h = box.height;
			} catch {
				const rect = svg.getBoundingClientRect();
				w = rect.width;
				h = rect.height;
			}
		}

		if (!w || !h) return null;
		return { w, h };
	}

	function fitToView() {
		const dims = measureStage();
		if (!dims || !viewport) return;

		const margin = 48;
		const availW = Math.max(viewport.clientWidth - margin, 120);
		const availH = Math.max(viewport.clientHeight - margin, 120);
		const fitScale = Math.min(availW / dims.w, availH / dims.h);
		scale = clamp(fitScale, MIN_SCALE, MAX_SCALE);
		panX = (viewport.clientWidth - dims.w * scale) / 2;
		panY = (viewport.clientHeight - dims.h * scale) / 2;
		applyTransform();
	}

	function resetTransform() {
		fitToView();
	}

	function ensureModal() {
		if (modal) return;

		modal = document.createElement('div');
		modal.className = 'mermaid-modal';
		modal.setAttribute('role', 'dialog');
		modal.setAttribute('aria-modal', 'true');
		modal.setAttribute('aria-label', 'Expanded diagram');
		modal.hidden = true;

		modal.innerHTML = `
			<button type="button" class="mermaid-modal-backdrop" aria-label="Close diagram"></button>
			<div class="mermaid-modal-panel">
				<header class="mermaid-modal-toolbar">
					<span class="mermaid-modal-title">Architecture diagram</span>
					<div class="mermaid-modal-zoom" role="group" aria-label="Zoom controls">
						<button type="button" data-zoom="out" aria-label="Zoom out">−</button>
						<button type="button" data-zoom="reset" class="mermaid-modal-scale" aria-label="Reset zoom">100%</button>
						<button type="button" data-zoom="in" aria-label="Zoom in">+</button>
					</div>
					<button type="button" class="mermaid-modal-close" aria-label="Close">×</button>
				</header>
				<div class="mermaid-modal-viewport" tabindex="0">
					<div class="mermaid-modal-stage"></div>
				</div>
				<p class="mermaid-modal-hint">Drag to pan · Scroll to zoom · Esc to close</p>
			</div>
		`;

		document.body.appendChild(modal);

		viewport = modal.querySelector('.mermaid-modal-viewport');
		stage = modal.querySelector('.mermaid-modal-stage');
		scaleLabel = modal.querySelector('.mermaid-modal-scale');

		modal.querySelector('.mermaid-modal-backdrop').addEventListener('click', closeModal);
		modal.querySelector('.mermaid-modal-close').addEventListener('click', closeModal);

		modal.querySelector('[data-zoom="in"]').addEventListener('click', () => {
			scale = clamp(scale + ZOOM_STEP, MIN_SCALE, MAX_SCALE);
			applyTransform();
		});
		modal.querySelector('[data-zoom="out"]').addEventListener('click', () => {
			scale = clamp(scale - ZOOM_STEP, MIN_SCALE, MAX_SCALE);
			applyTransform();
		});
		modal.querySelector('[data-zoom="reset"]').addEventListener('click', resetTransform);

		viewport.addEventListener(
			'wheel',
			(event) => {
				event.preventDefault();
				const delta = event.deltaY < 0 ? ZOOM_STEP : -ZOOM_STEP;
				scale = clamp(scale + delta, MIN_SCALE, MAX_SCALE);
				applyTransform();
			},
			{ passive: false }
		);

		viewport.addEventListener('pointerdown', (event) => {
			if (event.button !== 0) return;
			if (event.target.closest('button')) return;
			dragging = true;
			dragStart = { x: event.clientX, y: event.clientY, panX, panY };
			viewport.setPointerCapture(event.pointerId);
			viewport.classList.add('is-dragging');
		});

		viewport.addEventListener('pointermove', (event) => {
			if (!dragging) return;
			panX = dragStart.panX + (event.clientX - dragStart.x);
			panY = dragStart.panY + (event.clientY - dragStart.y);
			applyTransform();
		});

		viewport.addEventListener('pointerup', (event) => {
			if (!dragging) return;
			dragging = false;
			viewport.releasePointerCapture(event.pointerId);
			viewport.classList.remove('is-dragging');
		});

		viewport.addEventListener('pointercancel', () => {
			dragging = false;
			viewport.classList.remove('is-dragging');
		});

		document.addEventListener('keydown', (event) => {
			if (!modal || modal.hidden) return;
			if (event.key === 'Escape') {
				event.preventDefault();
				closeModal();
			}
		});
	}

	function restoreSvgToArticle() {
		if (!activeSession) return;
		const { pre, placeholder } = activeSession;
		const svg = stage?.querySelector('svg');
		if (svg && placeholder.parentNode) {
			placeholder.parentNode.insertBefore(svg, placeholder);
			placeholder.remove();
		}
		pre.classList.remove('mermaid-modal-source-active');
		activeSession = null;
	}

	function openModal(svg, pre, title) {
		if (activeSession) {
			closeModal();
		}

		ensureModal();
		lastFocused = document.activeElement;

		const titleEl = modal.querySelector('.mermaid-modal-title');
		if (titleEl) titleEl.textContent = title || 'Architecture diagram';

		const placeholder = document.createComment('mermaid-expand-placeholder');
		svg.parentNode.insertBefore(placeholder, svg);
		stage.replaceChildren();
		stage.appendChild(svg);

		activeSession = { pre, placeholder };
		pre.classList.add('mermaid-modal-source-active');

		modal.hidden = false;
		document.body.classList.add('mermaid-modal-open');
		modal.querySelector('.mermaid-modal-close').focus();

		requestAnimationFrame(() => {
			requestAnimationFrame(fitToView);
		});
	}

	function closeModal() {
		if (!modal || modal.hidden) return;
		restoreSvgToArticle();
		modal.hidden = true;
		document.body.classList.remove('mermaid-modal-open');
		if (lastFocused && typeof lastFocused.focus === 'function') {
			lastFocused.focus();
		}
	}

	function diagramTitle(pre) {
		const shell = pre.closest('.mermaid-diagram-shell');
		const root = shell?.parentElement ?? pre.parentElement;
		if (!root) return 'Diagram';

		let el = shell ?? pre;
		while (el) {
			el = el.previousElementSibling;
			if (!el) break;
			if (/^H[1-6]$/.test(el.tagName)) {
				return el.textContent.trim();
			}
			const heading = el.querySelector?.('h1, h2, h3, h4, h5, h6');
			if (heading) return heading.textContent.trim();
		}
		return 'Diagram';
	}

	function wrapDiagram(pre) {
		if (pre.getAttribute(ENHANCED) === 'true') return;
		if (!pre.hasAttribute(PROCESSED)) return;
		if (pre.querySelector('[style*="color: red"]')) return;

		const svg = pre.querySelector('svg');
		if (!svg) return;

		const shell = document.createElement('div');
		shell.className = WRAP_CLASS;

		const trigger = document.createElement('button');
		trigger.type = 'button';
		trigger.className = 'mermaid-expand-trigger';
		trigger.setAttribute('aria-label', 'Expand diagram to full screen');
		trigger.innerHTML =
			'<span class="mermaid-expand-icon" aria-hidden="true"></span><span>Expand diagram</span>';

		pre.parentNode.insertBefore(shell, pre);
		shell.appendChild(pre);
		shell.appendChild(trigger);

		const open = () => {
			const liveSvg = pre.querySelector('svg');
			if (!liveSvg) return;
			openModal(liveSvg, pre, diagramTitle(pre));
		};

		trigger.addEventListener('click', (e) => {
			e.preventDefault();
			e.stopPropagation();
			open();
		});

		pre.addEventListener('click', (e) => {
			if (e.target.closest('a, button')) return;
			open();
		});

		pre.setAttribute(ENHANCED, 'true');
		pre.setAttribute('tabindex', '0');
		pre.setAttribute('role', 'button');
		pre.setAttribute('aria-label', 'Expand diagram: ' + diagramTitle(pre));
		pre.addEventListener('keydown', (e) => {
			if (e.key === 'Enter' || e.key === ' ') {
				e.preventDefault();
				open();
			}
		});
	}

	function enhanceAll() {
		document.querySelectorAll('pre.mermaid').forEach(wrapDiagram);
	}

	const observer = new MutationObserver(enhanceAll);
	observer.observe(document.documentElement, {
		subtree: true,
		childList: true,
		attributes: true,
		attributeFilter: [PROCESSED, ENHANCED],
	});

	document.addEventListener('astro:after-swap', () => {
		if (activeSession) closeModal();
		requestAnimationFrame(enhanceAll);
	});

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', enhanceAll);
	} else {
		enhanceAll();
	}
})();
