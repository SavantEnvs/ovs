/* Fuzz harness: an LLDP frame as ovs-vswitchd receives it on a port with lldp:enable=true
 * (ofproto -> lldp_process_packet -> lldpd_recv -> lldp_decode). Each input is a whole
 * Ethernet frame, delivered in its own exactly-sized dp_packet buffer, to a fresh dummy
 * LLDP instance (lldp_create_dummy, the one OVS's own unit tests use). */
#include <config.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "dp-packet.h"
#include "lldp/lldpd.h"
#include "ovs-lldp.h"
#include "openvswitch/list.h"
#include "openvswitch/vlog.h"

int LLVMFuzzerInitialize(int *argc, char ***argv);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int
LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void) argc;
    (void) argv;
    vlog_set_levels(NULL, VLF_ANY_DESTINATION, VLL_OFF);
    return 0;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    struct lldp *lldp = lldp_create_dummy();
    struct lldpd_hardware *hw;
    struct lldpd_chassis *chassis;
    struct dp_packet packet;
    uint8_t *frame = malloc(size ? size : 1);

    memcpy(frame, data, size);
    dp_packet_use_const(&packet, frame, size);
    lldp_process_packet(lldp, &packet);

    /* Release what decoding stored: the neighbours and their chassis. */
    LIST_FOR_EACH (hw, h_entries, &lldp->lldpd->g_hardware) {
        lldpd_remote_cleanup(hw, NULL, true);
    }
    LIST_FOR_EACH (chassis, list, &lldp->lldpd->g_chassis) {
        lldpd_chassis_cleanup(chassis, false);
    }
    lldp_destroy_dummy(lldp);
    free(frame);
    return 0;
}
