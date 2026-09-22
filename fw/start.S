/* start.S -- reset and interrupt vectors for PicoRV32.
 *
 * PicoRV32 is configured with PROGADDR_RESET = 0x0000_0000 and
 * PROGADDR_IRQ = 0x0000_0010, so the IRQ vector must sit at exactly 0x10.
 * IRQs are masked at reset and the firmware never unmasks them, so the
 * handler is a safety net that should never execute.
 */
    .section .text.start, "ax"
    .globl _start
_start:
    j       reset

    .balign 16                  /* pad to 0x10 */
irq_vector:
    j       irq_vector          /* unreachable while IRQs stay masked */

reset:
    la      sp, _stack_top

    /* zero .bss */
    la      t0, _bss_start
    la      t1, _bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    /* copy .data from ROM to RAM */
    la      t0, _data_load
    la      t1, _data_start
    la      t2, _data_end
3:  bgeu    t1, t2, 4f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       3b
4:
    call    main
5:  j       5b                  /* main never returns */
