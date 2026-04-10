[BITS 16]
[ORG 0x7c00]

start:
    mov [BOOT_DRIVE], dl

    ; Print "OS"
    mov ah, 0x0e
    mov al, 'O'
    int 0x10
    mov al, 'S'
    int 0x10
    mov al, ' '
    int 0x10

    ; Load kernel (10 sectors from sector 2)
    mov bx, 0x1000
    mov al, 10
    mov dl, [BOOT_DRIVE]
    mov ah, 0x02
    mov ch, 0x00
    mov cl, 0x02
    mov dh, 0x00
    int 0x13
    jc disk_error

    jmp 0x0000:0x1000

disk_error:
    mov ah, 0x0e
    mov al, 'E'
    int 0x10
    jmp $

BOOT_DRIVE db 0
times 510-($-$$) db 0
dw 0xaa55