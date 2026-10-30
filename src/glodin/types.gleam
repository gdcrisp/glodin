//// Opaque BEAM values exchanged with native functions.
////
//// These types describe values held by BEAM. They do not grant native code
//// permission to retain a call-scoped term; see the ownership guide.

/// An arbitrary Erlang term. Native codecs can convert it to a concrete type.
pub type Term

/// An Erlang atom. Creating unbounded atoms can exhaust the VM's atom table.
pub type Atom

/// An Erlang process identifier; the referenced process may have exited.
pub type Pid

/// An Erlang reference, suitable for identity and correlation.
pub type Reference
