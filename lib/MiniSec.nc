#include "crypto.h"
interface MiniSec {
	command error_t init(CipherModeContext *cc, uint8_t *key, uint8_t key_size, uint8_t *iv,
                            uint8_t num_precomp_blks);
	command error_t encrypt(CipherModeContext *cc, uint8_t *data, uint8_t length, uint8_t *taggy, 
								 uint8_t tag_len);
	command error_t decrypt(CipherModeContext *cc, uint8_t *cipher_blocks, uint8_t *plain_blocks, 
                                uint8_t cipher_len, uint8_t *taggy, uint8_t *valid);
}