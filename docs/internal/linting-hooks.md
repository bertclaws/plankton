# Linting Hooks — How I Described Them

Extracted verbatim descriptions and key points from interview transcript, narrative prep, and post-interview reflections.

---

## Naming and Framing

I call them **"Slop Gates"** — a playful name for hooks that lint and correct code at write-time, not after commit.

> "Ho portato il mio lavoro che ho fatto su Lux, io li chiamo Slop Gates praticamente, in modo molto divertente"

---

## Core Mechanism: Write-Time Linting (Not Post-Commit)

The agent writes code. Linting happens immediately as a tool-call-level **Stop hook**, not as a pre-commit step. The key distinction from pre-commits: the code is linted **while it is being written**, not after a commit attempt.

> "L'agente che scrive il codice fa girare l'inter mentre lo scrive, cioè [...] c'è uno stop hook che praticamente linta il codice immediatamente mentre viene il codice. viene scritto, cioè la gente scrive il codice, viene lintato proprio a livello di tool call immediatamente"

**Result:** "I practically don't receive pre-commit warnings anymore."

---

## Architecture: Main Agent + Subprocesses

The system has a layered architecture:

1. **Autoformatting first** — equivalent to running Black or Ruff's formatter. Fires immediately on write.

2. **Subprocess linter correction** — behind the autoformatter, there are **subprocesses** (not the main agent) that quickly fix remaining linting and formatting errors.

3. **Escalation to main agent** — when subprocesses can't fix errors (complexity too high, error count exceeds a threshold, or the fix requires a module-level refactor), they return a message to the main agent saying the linter couldn't correct these errors, fix them yourself.

> "C'è il main agent che prova a fare una scrittura di codice, c'è il — innanzitutto c'è subito l'autoformatting, quindi fa subito immaginatevi un black o un rough che fa l'autoformatting dei codici immediatamente. Poi dietro se l'autoformatting emette anche degli errori e dei warning, dietro ci sono dei subprocesses, quindi non è il main agent, che in modo molto veloce vanno a correggere gli errori rimanenti a livello di linting e di formattazione. E se non ci riescono, quando non ci riescono perché la complessità è troppo elevata, si va sopra un numero di errori particolare, a seconda poi anche del tipo di codice, di complessità eccetera, tornano un messaggio al main agent che dice [...] l'inter non è riuscito a correggere questi errori, correggili tu."

---

## Speed Requirement: Rust-Based Linters

The subprocesses must be **extremely fast** to avoid timing conflicts. All linters are Rust-based (e.g., Ruff) because delays can cause conflicts between different linters running concurrently.

> "Questo richiede degli inter velocissimi, sono praticamente tutti basati su Rust perché questi delay può portare a degli scontri, dei conflitti tra diversi linter"

---

## Configurability

All rules are customizable through config. Teams can change linting and formatting rules over time. Ruff and similar tools offer an extremely wide range of enforceable rules.

> "Possiamo cambiare idea, possiamo estenderlo o meno a determinati tipi di formatting, linting, regole specifiche tipo quelle di graph che sono un migliaio."

> "Tutte le regole sono configurabili [...] RAF, gli altri inter ti permettono praticamente di settare proprio esattamente il tipo di regola di cui tu vuoi fare l'enforcement e hanno un range di regole ampissimo."

---

## Language Coverage

Configurable across the full range of scripting languages: **Python, TypeScript, CSS, HTML**, etc.

> "Sono configurabili e vanno praticamente in tutto lo span di quello che è lo scripting classico, quindi Python, TypeScript, CSS, HTML eccetera"

---

## Transparency to the Main Agent

The correction loop is mostly invisible to the main agent. The main agent writes code, the subprocesses handle linting/formatting silently, and the main agent barely notices the process happening.

> "Molto spesso, almeno nel mio utilizzo, il main agent quasi non se ne accorge che questo processo avviene, ma il risultato è che il codice sempre formattato limitato esattamente come lo vuoi"

---

## Comparison to Pre-Commits (Giulio's Question)

Giulio asked how these differ from pre-commits. The distinction:

- **Pre-commits:** You write code, try to commit, errors appear, you copy-paste errors, give them to the agent, the agent fixes them, you repeat this infinite loop.
- **Linting hooks:** The code is corrected at write-time by subprocesses. The loop never reaches the commit stage because errors are caught and fixed live.

> "Guardiamo al processo manuale, quale sarebbe: tu scrivi il codice, poi fai girare i tuoi formatter, oppure puoi fare in modo che siano automatizzati in qualche modo chiaramente. Poi dopo provi a committare, escono agli errori, copy-pasti gli errori, gli dai la gente, guarda ci sono questi problemi e lui va a sistemarli, continui in questo flusso infinito. Con i MeyUk questa cosa non succede"

Giulio's own analogy: it's like the **live linting** that IDEs (VS Code, Neovim) provided before agentic coding — underlining errors in real-time so you don't have to wait for the commit.

> "È come se stessi simulando quando prima dei clankers, quando scrive [...] su VS Code o anche su New Vim e così via quando ti faceva live linting, per cui ti faceva underlining delle cose sbagliate e non devi aspettare il commit."

---

## Beyond Style: Architectural and Separation-of-Concerns Enforcement

The hooks can enforce more than just style. They can (and should, as a planned evolution) enforce:

- **File placement rules** — Pydantic models must go in a specific location, tests must follow a specific structure
- **Complexity limits** — if a module is too complex, the linter signals it should be split into helper functions in separate files
- **Line count limits** — modules can have a max line count, forcing restructuring
- **Separation of concerns** — preventing monolithic files, enforcing modular architecture

These architectural signals enter the main agent's reasoning loop, acting like **reinforcement learning signals** that help the agent understand how to structure code correctly while writing it.

> "Tu puoi anche forzare considerazioni architetturali ma anche forzare considerazioni di separation of concerns [...] tu puoi avere delle regole specifiche su dove devono andare le cose nella tua codebase per esempio i Pydantic module devono andare lì i test devono andare sempre con questa struttura [...] il modello quando scrive più parti di codice, non si inventa più mette il file di là, mette il file di qui, no, il file deve andare qua e questo viene forzato dal look nel momento in cui viene scritto"

> "Ci sono degli errori che dicono guarda questa cosa è troppo complessa, per esempio separala in dei helper function per esempio no? E l'helper function mettila in un file separato, non tenerla dentro lo stesso modulo che poi il modulo diventa gigantesco 500.000 righe. Oppure anche il numero di linee che un certo modulo può avere può venire limitato"

---

## Reinforcement Learning Analogy

The hooks function as a **feedback signal** to the main agent — similar to reinforcement learning. They provide real-time positive/corrective signals that the agent incorporates into its reasoning while writing code.

> "Danno dei segnali positivi al main agent che li tiene in considerazione mentre scrive il codice e aiutano a ragionare meglio a dargli contesto su [...] sulla code base sulle regole che tu hai deciso"

This replaces the common approach of writing a prompt file with rules (e.g., "don't write lines over X length, don't use complexity over Y"). Instead of relying on prompting, the constraints are **enforced programmatically** at write-time.

> "Molto spesso quello che si fa è adesso scrivere tipo un file con queste regole tipo prompt no non scrivere mai [...] non usare una complessità oltre a tot e invece con [hooks] non ti devi preoccupare di questa cosa ma viene forzata nel momento in cui viene scritto"

---

## Error Routing by Type

The system has branching logic based on error type. Different kinds of errors get handled differently:

- Simple formatting errors: handled by subprocesses automatically
- Errors requiring module refactoring: escalated to main agent
- Threshold-based: error count, code complexity, and error type all factor into routing

> "È molto più complesso perché tipo a seconda del tipo di errore, se è un errore di [...] che richiede un refactor di un modulo qualcosa ci sono un sacco di logiche praticamente qua dentro"

---

## Proven in Practice: Flywheel Without vs With Hooks

Tested the Flywheel agent with and without the hooks:

- **Without hooks:** The agent generates files, runs them, gets linting/formatting errors, has to go back and fix them, losing context in the process.
- **With hooks:** Subprocesses handle all linting/formatting correction. The main agent focuses only on the experiment logic, never distracted by style issues.

> "Io ho provato a far giocare il flywheel senza questi [hooks]: quello che succedeva è che faceva la solita roba, generava questi file poi li faceva girare uscivano gli errori doveva tornare indietro e quindi perdeva un sacco di contesto [...] con quest'[hooks] faceva il file, siccome i subprocess si occupano di fare tutta questa correzione degli errori dell'inting e il mio agente si preoccupava solo dell'esperimento"

---

## Longevity Debate (Giulio's Pushback)

Giulio pushed back: won't future models (e.g., "Claude 4.9") be smart enough that they won't need these signals?

**My response:** Agreed that models will improve and this harnessing will become less relevant over time. But there will always be contexts where users have very opinionated style preferences that prompting alone can't handle or where prompts become too extensive. The hooks may continue to have a role even with smarter models.

> "Sicuramente sono d'accordo che nel lungo andare i modelli diventeranno sempre più intelligenti, quindi questo tipo di harnessing diventerà sempre meno rilevante. Potrebbe comunque esserci sempre un contesto in cui l'utente magari è molto opinionato, molto molto opinionato. Il prompting non basta o il prompting diventa troppo esteso e quindi magari questi potrebbero continuare ad avere un ruolo anche in quel caso."

**Follow-up nuance:** Needs to be re-evaluated step by step to avoid carrying unnecessary bloat.

> "Adesso aiutano, domani vediamo e va rivalutato passo per passo per non portarsi dietro un blotto che è inutile"

---

## From the Narrative Prep Document

The narrative document describes the hooks within the broader harness work and the pre-commit enforcement approach:

> "All the work I did at the harness level with lux and pre-commit checks is also in that direction — we establish very precise rules about style, formatting, and test creation that are all enforceable by [linting], so we ensure that at least at the style level, separation of concerns level, and testing level, tests are written exactly how we want them, with rules that are customizable and can change over time."

The hooks are described as part of a broader **context engineering** approach where the linting signals help the agent reason better about code structure — not just catch errors, but actively shape how the agent thinks about architecture while generating code.
