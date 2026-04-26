# Ruby 3.2+ removed taint methods — patch them as no-ops for Liquid 4 compatibility
class Object
  def taint; self; end
  def untaint; self; end
  def tainted?; false; end
  def trust; self; end
  def untrust; self; end
  def trusted?; true; end
end
