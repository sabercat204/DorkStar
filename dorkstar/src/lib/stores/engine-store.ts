import { writable, get } from 'svelte/store';
import type { EngineId, EngineCategory } from '../translation/types';
import { ENGINE_REGISTRY } from '../translation/adapters/registry';
import { ALL_ENGINE_IDS } from '../translation/types';
import { emitCmd, cmd } from './cmd-log';

export interface PersistedEngineState {
	activeEngines: EngineId[];
	engineOrder: EngineId[];
	lastUpdated: string;
}

const STORAGE_KEY = 'dorkstar-engine-state';

// Initialize with all engines active, in registry order
const initialEngines = ALL_ENGINE_IDS as unknown as EngineId[];

export const activeEngines = writable<EngineId[]>([...initialEngines]);
export const engineOrder = writable<EngineId[]>([...initialEngines]);

export function toggleEngine(id: EngineId): void {
	const wasActive = get(activeEngines).includes(id);
	activeEngines.update((engines) => {
		if (engines.includes(id)) {
			return engines.filter((e) => e !== id);
		} else {
			return [...engines, id];
		}
	});
	emitCmd(cmd.engineToggle(id, !wasActive));
	persistToLocalStorage();
}

export function toggleAll(): void {
	const allActive = get(activeEngines).length === ALL_ENGINE_IDS.length;
	activeEngines.update((engines) => {
		if (engines.length === ALL_ENGINE_IDS.length) {
			return []; // deactivate all
		} else {
			return [...ALL_ENGINE_IDS] as EngineId[]; // activate all
		}
	});
	emitCmd(cmd.engineAll(!allActive));
	persistToLocalStorage();
}

export function toggleCategory(category: EngineCategory): void {
	const categoryEngines = ENGINE_REGISTRY.filter((e) => e.category === category).map((e) => e.id);
	const allActive = categoryEngines.every((id) => get(activeEngines).includes(id));

	activeEngines.update((engines) => {
		if (allActive) {
			return engines.filter((id) => !categoryEngines.includes(id));
		} else {
			const newEngines = [...engines];
			for (const id of categoryEngines) {
				if (!newEngines.includes(id)) newEngines.push(id);
			}
			return newEngines;
		}
	});
	emitCmd(cmd.engineCategory(category, !allActive));
	persistToLocalStorage();
}

export function reorderEngines(fromIndex: number, toIndex: number): void {
	const order = get(engineOrder);
	const fromId = order[fromIndex] ?? '?';
	const toId = order[toIndex] ?? '?';
	engineOrder.update((order) => {
		const newOrder = [...order];
		const [moved] = newOrder.splice(fromIndex, 1);
		newOrder.splice(toIndex, 0, moved);
		return newOrder;
	});
	emitCmd(cmd.engineReorder(fromId, toId));
	persistToLocalStorage();
}

export function persistToLocalStorage(): void {
	if (typeof localStorage === 'undefined') return;
	const state: PersistedEngineState = {
		activeEngines: get(activeEngines),
		engineOrder: get(engineOrder),
		lastUpdated: new Date().toISOString()
	};
	localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
}

export function loadFromLocalStorage(): void {
	if (typeof localStorage === 'undefined') return;
	try {
		const raw = localStorage.getItem(STORAGE_KEY);
		if (!raw) return;
		const state: PersistedEngineState = JSON.parse(raw);
		if (Array.isArray(state.activeEngines)) {
			activeEngines.set(
				state.activeEngines.filter((id) => ALL_ENGINE_IDS.includes(id as EngineId))
			);
		}
		if (Array.isArray(state.engineOrder)) {
			engineOrder.set(
				state.engineOrder.filter((id) => ALL_ENGINE_IDS.includes(id as EngineId))
			);
		}
	} catch {
		// Ignore parse errors — use defaults
	}
}
