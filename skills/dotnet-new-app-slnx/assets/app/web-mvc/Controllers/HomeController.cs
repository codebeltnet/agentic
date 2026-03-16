using Microsoft.AspNetCore.Mvc;

namespace {ROOT_NAMESPACE}.{AppType}.Controllers;

public sealed class HomeController : Controller
{
    [HttpGet]
    public IActionResult Index()
    {
        return View();
    }
}
