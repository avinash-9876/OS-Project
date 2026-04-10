[BITS 16]
[ORG 0x1000]

; ═══════════════════════════════════════════════════════
;  PRIORITY-BASED RTOS — FULL VERSION (Phases 1-7)
;
;  Task1 Priority=1 (HIGHEST) → prints 'A'
;  Task2 Priority=2 (MEDIUM)  → prints 'B'
;  Task3 Priority=3 (LOWEST)  → prints 'C'
;
;  Features:
;   - Task Control Blocks (TCB)
;   - Per-task stacks
;   - Timer Interrupt (IRQ0/PIT)
;   - Context Save/Restore
;   - Task States: READY/RUNNING/BLOCKED
;   - Preemptive Priority Scheduler
;   - Idle Task
; ═══════════════════════════════════════════════════════

; ── Task State Constants ─────────────────────────────
TASK_READY   equ 0
TASK_RUNNING equ 1
TASK_BLOCKED equ 2

; ── Stack sizes ──────────────────────────────────────
STACK_SIZE   equ 128

; ════════════════════════════════════════════════════
;  ENTRY POINT
; ════════════════════════════════════════════════════
start:
    cli                         ; disable interrupts during setup

    ; Setup segment registers
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; Setup kernel stack (below 0x1000)
    mov sp, 0x0FF0

    ; ── Phase 3: Setup PIT (Timer) ──────────────────
    ; PIT Channel 0, frequency divisor = 0x4000
    ; Slows timer so output is readable
    mov al, 0x36            ; Channel 0, lobyte/hibyte, mode 3
    out 0x43, al
    mov ax, 0x4000          ; divisor
    out 0x40, al            ; low byte
    mov al, ah
    out 0x40, al            ; high byte

    ; ── Remap PIC (IRQ0 → INT 0x20) ─────────────────
    ; Master PIC init
    mov al, 0x11
    out 0x20, al            ; init master PIC
    out 0xA0, al            ; init slave PIC
    mov al, 0x20
    out 0x21, al            ; master IRQ base = 0x20
    mov al, 0x28
    out 0xA1, al            ; slave IRQ base = 0x28
    mov al, 0x04
    out 0x21, al            ; master has slave at IRQ2
    mov al, 0x02
    out 0xA1, al            ; slave cascade identity
    mov al, 0x01
    out 0x21, al            ; 8086 mode
    out 0xA1, al
    ; Mask all IRQs except IRQ0 (timer)
    mov al, 0xFE            ; 11111110 — only IRQ0 unmasked
    out 0x21, al
    mov al, 0xFF
    out 0xA1, al

    ; ── Install Timer ISR at INT 0x20 ────────────────
    mov word [0x20*4],   timer_isr   ; offset
    mov word [0x20*4+2], 0x0000      ; segment

    ; ── Phase 5: Initialize TCBs ─────────────────────
    call init_tasks

    ; ── Set current task to Task1 (highest priority) ─
    mov byte [current_task], 0

    ; ── Switch to Task1 to begin ─────────────────────
    sti                         ; enable interrupts — RTOS is live!

    ; Load Task1's stack and jump to it
    mov sp, [tcb0_sp]
    jmp task1

; ════════════════════════════════════════════════════
;  PHASE 5: TASK CONTROL BLOCKS (TCB) INITIALIZATION
;  TCB Layout per task:
;    sp       (2 bytes) — saved stack pointer
;    state    (1 byte)  — READY/RUNNING/BLOCKED
;    priority (1 byte)  — 1=highest, 3=lowest
; ════════════════════════════════════════════════════
init_tasks:
    ; Task 0 (Task1) — Priority 1
    mov word [tcb0_sp],       stack0_top
    mov byte [tcb0_state],    TASK_READY
    mov byte [tcb0_priority], 1

    ; Task 1 (Task2) — Priority 2
    mov word [tcb1_sp],       stack1_top
    mov byte [tcb1_state],    TASK_READY
    mov byte [tcb1_priority], 2

    ; Task 2 (Task3) — Priority 3
    mov word [tcb2_sp],       stack2_top
    mov byte [tcb2_state],    TASK_READY
    mov byte [tcb2_priority], 3

    ; Idle Task — Priority 255 (lowest possible)
    mov word [tcb_idle_sp],       stack_idle_top
    mov byte [tcb_idle_state],    TASK_READY
    mov byte [tcb_idle_priority], 0xFF
    ret

; ════════════════════════════════════════════════════
;  PHASE 3+4+6: TIMER ISR — PREEMPTIVE SCHEDULER
;  Called by IRQ0 every timer tick
;  1. Save context of current task
;  2. Find highest priority READY task
;  3. Restore context of next task
; ════════════════════════════════════════════════════
timer_isr:
    pusha                       ; Phase 4: Save all registers

    ; ── Save current task's stack pointer ────────────
    mov al, [current_task]
    cmp al, 0
    je  .save_t0
    cmp al, 1
    je  .save_t1
    cmp al, 2
    je  .save_t2
    jmp .save_idle
.save_t0:
    mov [tcb0_sp], sp
    mov byte [tcb0_state], TASK_READY
    jmp .find_next
.save_t1:
    mov [tcb1_sp], sp
    mov byte [tcb1_state], TASK_READY
    jmp .find_next
.save_t2:
    mov [tcb2_sp], sp
    mov byte [tcb2_state], TASK_READY
    jmp .find_next
.save_idle:
    mov [tcb_idle_sp], sp
    mov byte [tcb_idle_state], TASK_READY

    ; ── Phase 6: Find highest priority READY task ────
.find_next:
    ; Default to idle task
    mov byte [next_task], 3         ; 3 = idle

    ; Check Task0 (priority 1)
    mov al, [tcb0_state]
    cmp al, TASK_READY
    jne .chk1
    mov byte [next_task], 0
    jmp .switch

.chk1:
    ; Check Task1 (priority 2)
    mov al, [tcb1_state]
    cmp al, TASK_READY
    jne .chk2
    mov byte [next_task], 1
    jmp .switch

.chk2:
    ; Check Task2 (priority 3)
    mov al, [tcb2_state]
    cmp al, TASK_READY
    jne .switch
    mov byte [next_task], 2

    ; ── Context Switch to next task ──────────────────
.switch:
    mov al, [next_task]
    mov [current_task], al

    ; Mark next task as RUNNING
    cmp al, 0
    je  .run_t0
    cmp al, 1
    je  .run_t1
    cmp al, 2
    je  .run_t2
    jmp .run_idle

.run_t0:
    mov byte [tcb0_state], TASK_RUNNING
    mov sp, [tcb0_sp]
    jmp .done
.run_t1:
    mov byte [tcb1_state], TASK_RUNNING
    mov sp, [tcb1_sp]
    jmp .done
.run_t2:
    mov byte [tcb2_state], TASK_RUNNING
    mov sp, [tcb2_sp]
    jmp .done
.run_idle:
    mov byte [tcb_idle_state], TASK_RUNNING
    mov sp, [tcb_idle_sp]

.done:
    ; Send EOI to PIC (End Of Interrupt)
    mov al, 0x20
    out 0x20, al

    popa                        ; Phase 4: Restore registers of next task
    iret                        ; Return into next task

; ════════════════════════════════════════════════════
;  PHASE 2+6: TASK DEFINITIONS
;  Each task runs, prints its char, delays, yields
; ════════════════════════════════════════════════════

; ── Task 1: Highest Priority → prints 'A' ───────────
task1:
    mov ah, 0x0e
.loop:
    mov al, 'A'
    int 0x10
    call task_delay
    ; Block self → let lower priority tasks run
    mov byte [tcb0_state], TASK_BLOCKED
    ; Unblock Task2
    mov byte [tcb1_state], TASK_READY
    jmp .loop

; ── Task 2: Medium Priority → prints 'B' ────────────
task2:
    mov ah, 0x0e
.loop:
    mov al, 'B'
    int 0x10
    call task_delay
    ; Block self → let Task3 run
    mov byte [tcb1_state], TASK_BLOCKED
    ; Unblock Task3
    mov byte [tcb2_state], TASK_READY
    jmp .loop

; ── Task 3: Lowest Priority → prints 'C' ────────────
task3:
    mov ah, 0x0e
.loop:
    mov al, 'C'
    int 0x10
    call task_delay
    ; Block self → unblock Task1 (cycle restarts)
    mov byte [tcb2_state], TASK_BLOCKED
    ; Unblock Task1 (highest priority)
    mov byte [tcb0_state], TASK_READY
    jmp .loop

; ── Phase 7: IDLE TASK ───────────────────────────────
; Runs only when ALL other tasks are BLOCKED
idle_task:
.loop:
    hlt                         ; halt CPU until next interrupt
    jmp .loop

; ════════════════════════════════════════════════════
;  DELAY ROUTINE (used inside tasks)
; ════════════════════════════════════════════════════
task_delay:
    push cx
    mov cx, 0xffff
.d:
    loop .d
    pop cx
    ret

; ════════════════════════════════════════════════════
;  PHASE 5: TASK STACKS
;  Each task gets its own 128-byte stack
; ════════════════════════════════════════════════════
stack0:  times STACK_SIZE db 0
stack0_top:

stack1:  times STACK_SIZE db 0
stack1_top:

stack2:  times STACK_SIZE db 0
stack2_top:

stack_idle: times STACK_SIZE db 0
stack_idle_top:

; ════════════════════════════════════════════════════
;  PHASE 5: TCB DATA (Task Control Blocks)
; ════════════════════════════════════════════════════
tcb0_sp:       dw 0
tcb0_state:    db TASK_READY
tcb0_priority: db 1

tcb1_sp:       dw 0
tcb1_state:    db TASK_BLOCKED   ; starts blocked, Task1 unblocks it
tcb1_priority: db 2

tcb2_sp:       dw 0
tcb2_state:    db TASK_BLOCKED   ; starts blocked, Task2 unblocks it
tcb2_priority: db 3

tcb_idle_sp:       dw 0
tcb_idle_state:    db TASK_READY
tcb_idle_priority: db 0xFF

; ── Scheduler variables ──────────────────────────────
current_task: db 0              ; index of currently running task
next_task:    db 0              ; index chosen by scheduler