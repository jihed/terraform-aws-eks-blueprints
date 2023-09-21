variable "pool_list" {
  type = list(object({
    namespace = string
    pool      = string
  }))
  default = [
    {
      namespace = "tenant-a"
      pool      = "pool-a"
    },
    {
      namespace = "tenant-b"
      pool      = "pool-b"
    }
  ]
}
