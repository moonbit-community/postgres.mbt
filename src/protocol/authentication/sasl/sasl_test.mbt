///|
test "exchange" {
  let password = b"foobar"
  let nonce = b"9IZ2O01zb9IgiIZ1WJ/zgpJB"
  let client_first = b"n,,n=,r=9IZ2O01zb9IgiIZ1WJ/zgpJB"
  let server_first = b"r=9IZ2O01zb9IgiIZ1WJ/zgpJBjx/oIRLs02gGSHcw1KEty3eY,s=fs3IXBy7U7+IvVjZ,i=4096"
  let client_final = b"c=biws,r=9IZ2O01zb9IgiIZ1WJ/zgpJBjx/oIRLs02gGSHcw1KEty3eY,p=AmNKosjJzS31NTlQYNs5BTeQjdHdk7lOflDo5re2an8="
  let server_final = b"v=U+ppxD5XUKtradnv8e2MkeupiA8FU87Sg8CXzXHDAzw="
  let scram = ScramSha256::new_inner(
    password,
    ChannelBinding::unsupported(),
    nonce,
  )
  assert_eq((try! scram.message()).to_bytes(), client_first)
  try! scram.update(server_first)
  assert_eq((try! scram.message()).to_bytes(), client_final)
  try! scram.finish(server_final)
}
