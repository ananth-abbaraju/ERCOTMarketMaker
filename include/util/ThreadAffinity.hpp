#pragma once

#include <pthread.h>
#if defined(__APPLE__)
#  include <mach/mach.h>
#  include <mach/thread_policy.h>
#else
#  include <sched.h>
#endif

namespace util {

// Best-effort core pinning for a hot thread.
//
// macOS (especially Apple Silicon) exposes no real CPU affinity API -- THREAD_AFFINITY_POLICY
// is only an L2-cache-sharing hint and is documented as ignored on the SoCs (see ADR-001 in
// Documentation/ARCHITECTURE_NOTES.md) -- so on Apple we set the affinity tag harmlessly AND
// raise the thread's QoS class to USER_INTERACTIVE, which is the only lever that reliably
// biases the scheduler toward the performance cores. On Linux this is a hard affinity set via
// pthread_setaffinity_np.
//
// `tag` is the affinity group / CPU index: threads sharing a tag are hinted to share L2 on
// Apple; on Linux it is the target logical core.
inline void pin_thread(int tag) {
#if defined(__APPLE__)
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    thread_affinity_policy_data_t pol{ tag };
    thread_policy_set(pthread_mach_thread_np(pthread_self()),
                      THREAD_AFFINITY_POLICY, reinterpret_cast<thread_policy_t>(&pol),
                      THREAD_AFFINITY_POLICY_COUNT);
#else
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(tag, &set);
    pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
#endif
}

} // namespace util
